//+------------------------------------------------------------------+
//|                                                   TradeExec.mqh   |
//|                        ProGridEA v2 – Trade Execution Module      |
//|                                                                  |
//|  Builds MqlTradeRequest, validates with OrderCheck, sends with   |
//|  OrderSend, and classifies the retcode outcome.                  |
//|  v2: ATR-based SL/TP, safer retry (TOO_MANY_REQ retryable),     |
//|      CSV logging on trade open.                                  |
//+------------------------------------------------------------------+
#ifndef TRADEEXEC_MQH
#define TRADEEXEC_MQH

//===================================================================
// Retcode classification
//===================================================================
enum ENUM_EXEC_OUTCOME
{
   EXEC_OK             = 0,   // Trade placed / done
   EXEC_REQUOTE        = 1,   // Requote – can retry
   EXEC_PRICE_CHANGED  = 2,   // Price moved – can retry
   EXEC_NO_MONEY       = 3,   // Insufficient funds
   EXEC_TOO_MANY_REQ   = 4,   // Throttled – can retry with longer delay
   EXEC_MARKET_CLOSED  = 5,   // Market closed
   EXEC_INVALID        = 6,   // Invalid request / params
   EXEC_FATAL          = 7,   // Non-recoverable error
   EXEC_TIMEOUT        = 8    // Timeout / connection – can retry
};

ENUM_EXEC_OUTCOME ClassifyRetcode(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_DONE:
      case TRADE_RETCODE_DONE_PARTIAL:
      case TRADE_RETCODE_PLACED:
         return EXEC_OK;

      case TRADE_RETCODE_REQUOTE:
         return EXEC_REQUOTE;

      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
         return EXEC_PRICE_CHANGED;

      case TRADE_RETCODE_NO_MONEY:
         return EXEC_NO_MONEY;

      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return EXEC_TOO_MANY_REQ;

      case TRADE_RETCODE_MARKET_CLOSED:
         return EXEC_MARKET_CLOSED;

      case TRADE_RETCODE_INVALID:
      case TRADE_RETCODE_INVALID_VOLUME:
      case TRADE_RETCODE_INVALID_PRICE:
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_INVALID_EXPIRATION:
      case TRADE_RETCODE_INVALID_ORDER:
         return EXEC_INVALID;

      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
         return EXEC_TIMEOUT;

      default:
         return EXEC_FATAL;
   }
}

//===================================================================
// BuildMarketOrder – construct a market BUY or SELL request
//===================================================================
void BuildMarketOrder(MqlTradeRequest &req,
                      string symbol,
                      ENUM_ORDER_TYPE orderType,
                      double volume,
                      double sl,
                      double tp,
                      long magic,
                      string comment)
{
   ZeroMemory(req);

   req.action    = TRADE_ACTION_DEAL;          // Market execution
   req.symbol    = symbol;
   req.volume    = volume;
   req.type      = orderType;
   req.magic     = magic;
   req.comment   = comment;

   // Fill-or-kill by default; broker may override
   req.type_filling = ORDER_FILLING_FOK;

   // Set price depending on direction
   if(orderType == ORDER_TYPE_BUY)
      req.price = GetAsk(symbol);
   else
      req.price = GetBid(symbol);

   // Normalise SL / TP
   req.sl = (sl > 0) ? NormalisePrice(symbol, sl) : 0;
   req.tp = (tp > 0) ? NormalisePrice(symbol, tp) : 0;

   // Deviation (slippage) in points
   req.deviation = (uint)InpSlippage;
}

//===================================================================
// DetectFillingMode – pick a filling type accepted by the broker
//===================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode(string symbol)
{
   long fillFlags = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillFlags & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;

   if((fillFlags & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;   // exchange-style
}

//===================================================================
// ValidateRequest – run OrderCheck before sending
//===================================================================
bool ValidateRequest(MqlTradeRequest &req, MqlTradeCheckResult &checkResult)
{
   ZeroMemory(checkResult);

   if(!OrderCheck(req, checkResult))
   {
      LogWarn("TradeExec", StringFormat("OrderCheck FAILED – retcode=%u (%s) comment=%s",
               checkResult.retcode, RetcodeToString(checkResult.retcode), checkResult.comment));
      LogCheckResult(checkResult);
      return false;
   }

   LogDebug("TradeExec", StringFormat("OrderCheck OK – margin=%.2f free=%.2f",
             checkResult.margin, checkResult.margin_free));
   return true;
}

//===================================================================
// IsRetryable – should we retry this outcome? (v2: TOO_MANY_REQ too)
//===================================================================
bool IsRetryable(ENUM_EXEC_OUTCOME outcome)
{
   return (outcome == EXEC_REQUOTE ||
           outcome == EXEC_PRICE_CHANGED ||
           outcome == EXEC_TIMEOUT ||
           outcome == EXEC_TOO_MANY_REQ);
}

//===================================================================
// RetrySleepMs – escalating back-off with a hard cap (v2)
//===================================================================
int RetrySleepMs(ENUM_EXEC_OUTCOME outcome, int attempt)
{
   int baseMs = (outcome == EXEC_TOO_MANY_REQ) ? 1000 : 300;
   int ms     = baseMs * (attempt + 1);
   if(ms > 3000) ms = 3000;   // hard cap
   return ms;
}

//===================================================================
// SendOrder – validate + send a trade request (v2: safer retry)
//===================================================================
//  Returns true if the order was accepted by the server.
//  Fills 'result' with the server outcome.
//===================================================================
bool SendOrder(MqlTradeRequest &req, MqlTradeResult &result)
{
   ZeroMemory(result);

   //--- Auto-detect filling mode
   req.type_filling = DetectFillingMode(req.symbol);

   //--- Pre-validate (not retryable – structural issues)
   MqlTradeCheckResult checkRes;
   if(!ValidateRequest(req, checkRes))
   {
      result.retcode = checkRes.retcode;
      result.comment = checkRes.comment;
      return false;
   }

   //--- Retry loop for transient errors
   int maxRetries = MathMax(0, InpMaxRetries);

   for(int attempt = 0; attempt <= maxRetries; attempt++)
   {
      if(attempt > 0)
      {
         ENUM_EXEC_OUTCOME prevOutcome = ClassifyRetcode(result.retcode);
         int sleepMs = RetrySleepMs(prevOutcome, attempt);

         LogInfo("TradeExec", StringFormat("Retry %d/%d after %s – sleeping %dms",
                  attempt, maxRetries, RetcodeToString(result.retcode), sleepMs));
         Sleep(sleepMs);

         //--- Refresh price for market orders
         if(req.action == TRADE_ACTION_DEAL)
         {
            if(req.type == ORDER_TYPE_BUY)
               req.price = GetAsk(req.symbol);
            else
               req.price = GetBid(req.symbol);
         }
      }

      ZeroMemory(result);
      LogTradeRequest(req);

      OrderSend(req, result);

      LogTradeResult(result);

      ENUM_EXEC_OUTCOME outcome = ClassifyRetcode(result.retcode);

      //--- Success
      if(outcome == EXEC_OK)
      {
         LogInfo("TradeExec", StringFormat("Order SUCCESS – ticket=%I64u retcode=%u (%s)",
                  result.order, result.retcode, RetcodeToString(result.retcode)));
         return true;
      }

      //--- Retryable?
      if(IsRetryable(outcome))
      {
         LogWarn("TradeExec", StringFormat("Retryable: %s (attempt %d/%d)",
                  RetcodeToString(result.retcode), attempt + 1, maxRetries + 1));
         if(attempt < maxRetries)
            continue;   // try again
         // else fall through – exhausted
         LogError("TradeExec", StringFormat("All %d retries exhausted – giving up", maxRetries + 1));
      }

      //--- Non-retryable or retries exhausted – log and exit
      switch(outcome)
      {
         case EXEC_NO_MONEY:
            LogError("TradeExec", "Insufficient funds – trade blocked");
            break;
         case EXEC_MARKET_CLOSED:
            LogWarn("TradeExec", "Market closed – cannot trade now");
            break;
         case EXEC_INVALID:
            LogError("TradeExec", StringFormat("Invalid request – %s", RetcodeToString(result.retcode)));
            break;
         default:
            LogError("TradeExec", StringFormat("Error – retcode=%u (%s)",
                      result.retcode, RetcodeToString(result.retcode)));
            break;
      }
      break;   // stop retrying
   }

   return false;
}

//===================================================================
// OpenMarketOrder – high-level wrapper used by the main EA
//===================================================================
//  v2: supports SLTP_FIXED and SLTP_ATR modes.
//  Computes SL/TP, calculates lot size, builds and sends request.
//  Returns true on success.
//===================================================================
bool OpenMarketOrder(string symbol,
                     ENUM_SIGNAL signal,
                     long magic,
                     string comment)
{
   if(signal == SIGNAL_NONE) return false;

   ENUM_ORDER_TYPE orderType = (signal == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double point   = GetPoint(symbol);
   double price   = (signal == SIGNAL_BUY) ? GetAsk(symbol) : GetBid(symbol);

   //--- Determine SL / TP in points
   double slPoints = 0, tpPoints = 0;

   if(InpSLTPMode == SLTP_ATR)
   {
      //--- ATR-based SL/TP (v2)
      double atr = GetCurrentATR();
      if(atr <= 0 || point <= 0)
      {
         LogWarn("TradeExec", "ATR unavailable – skipping trade");
         return false;
      }
      double atrPoints = atr / point;   // convert ATR value to points
      slPoints = atrPoints * InpATRMultSL;
      tpPoints = atrPoints * InpATRMultTP;
      LogDebug("TradeExec", StringFormat("ATR=%.5f atrPts=%.0f slPts=%.0f tpPts=%.0f",
                atr, atrPoints, slPoints, tpPoints));
   }
   else
   {
      //--- Fixed-point SL/TP
      slPoints = InpStopLoss;
      tpPoints = InpTakeProfit;
   }

   //--- Compute SL / TP prices
   double slPrice = 0, tpPrice = 0;
   if(slPoints > 0)
   {
      slPrice = (signal == SIGNAL_BUY) ? price - slPoints * point
                                       : price + slPoints * point;
   }
   if(tpPoints > 0)
   {
      tpPrice = (signal == SIGNAL_BUY) ? price + tpPoints * point
                                       : price - tpPoints * point;
   }

   //--- Lot sizing (uses SL in points for risk-per-trade mode)
   double lots = CalculateLotSize(symbol, slPoints);

   //--- Build request
   MqlTradeRequest req;
   BuildMarketOrder(req, symbol, orderType, lots, slPrice, tpPrice, magic, comment);

   //--- Send
   MqlTradeResult result;
   bool ok = SendOrder(req, result);

   if(ok)
   {
      RiskRecordTrade();   // Update cooldown + daily trade count

      //--- CSV log on successful open (v2)
      string dir = (signal == SIGNAL_BUY) ? "BUY" : "SELL";
      LogCSV("OPEN", symbol, dir, lots, result.price, req.sl, req.tp, 0, comment);
   }

   return ok;
}

#endif // TRADEEXEC_MQH
