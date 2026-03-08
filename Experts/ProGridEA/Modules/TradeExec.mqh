//+------------------------------------------------------------------+
//|                                                   TradeExec.mqh   |
//|                        ProGridEA – Trade Execution Module         |
//|                                                                  |
//|  Builds MqlTradeRequest, validates with OrderCheck, sends with   |
//|  OrderSend, and classifies the retcode outcome.                  |
//+------------------------------------------------------------------+
#ifndef TRADEEXEC_MQH
#define TRADEEXEC_MQH

#property strict

//===================================================================
// Retcode classification
//===================================================================
enum ENUM_EXEC_OUTCOME
{
   EXEC_OK             = 0,   // Trade placed / done
   EXEC_REQUOTE        = 1,   // Requote – can retry
   EXEC_PRICE_CHANGED  = 2,   // Price moved – can retry
   EXEC_NO_MONEY       = 3,   // Insufficient funds
   EXEC_TOO_MANY_REQ   = 4,   // Throttled
   EXEC_MARKET_CLOSED  = 5,   // Market closed
   EXEC_INVALID        = 6,   // Invalid request / params
   EXEC_FATAL          = 7    // Non-recoverable error
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
                      int magic,
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
   req.deviation = 20;
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
// SendOrder – validate + send a trade request
//===================================================================
//  Returns true if the order was accepted by the server.
//  Fills 'result' with the server outcome.
//===================================================================
bool SendOrder(MqlTradeRequest &req, MqlTradeResult &result)
{
   ZeroMemory(result);

   //--- Auto-detect filling mode
   req.type_filling = DetectFillingMode(req.symbol);

   //--- Pre-validate
   MqlTradeCheckResult checkRes;
   if(!ValidateRequest(req, checkRes))
   {
      // Map the check retcode into result so the caller can inspect it
      result.retcode = checkRes.retcode;
      result.comment = checkRes.comment;
      return false;
   }

   //--- Log the request
   LogTradeRequest(req);

   //--- Send
   bool ok = OrderSend(req, result);

   //--- Log the result
   LogTradeResult(result);

   //--- Classify
   ENUM_EXEC_OUTCOME outcome = ClassifyRetcode(result.retcode);

   if(outcome == EXEC_OK)
   {
      LogInfo("TradeExec", StringFormat("Order SUCCESS – ticket=%I64u retcode=%u (%s)",
               result.order, result.retcode, RetcodeToString(result.retcode)));
      return true;
   }

   //--- Handle non-OK outcomes with structured logging
   switch(outcome)
   {
      case EXEC_REQUOTE:
         LogWarn("TradeExec", "Requote received – will retry on next tick");
         break;
      case EXEC_PRICE_CHANGED:
         LogWarn("TradeExec", "Price changed – will retry on next tick");
         break;
      case EXEC_NO_MONEY:
         LogError("TradeExec", "Insufficient funds – trade blocked");
         break;
      case EXEC_TOO_MANY_REQ:
         LogWarn("TradeExec", "Too many requests – backing off");
         break;
      case EXEC_MARKET_CLOSED:
         LogWarn("TradeExec", "Market closed – cannot trade now");
         break;
      case EXEC_INVALID:
         LogError("TradeExec", StringFormat("Invalid request – %s", RetcodeToString(result.retcode)));
         break;
      case EXEC_FATAL:
      default:
         LogError("TradeExec", StringFormat("Fatal error – retcode=%u (%s)",
                   result.retcode, RetcodeToString(result.retcode)));
         break;
   }

   return false;
}

//===================================================================
// OpenMarketOrder – high-level wrapper used by the main EA
//===================================================================
//  Computes SL/TP prices from point distances, calculates lot size,
//  builds and sends the request.  Returns true on success.
//===================================================================
bool OpenMarketOrder(string symbol,
                     ENUM_SIGNAL signal,
                     int magic,
                     string comment)
{
   if(signal == SIGNAL_NONE) return false;

   ENUM_ORDER_TYPE orderType = (signal == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double point   = GetPoint(symbol);
   double price   = (signal == SIGNAL_BUY) ? GetAsk(symbol) : GetBid(symbol);

   //--- Compute SL / TP prices
   double slPrice = 0, tpPrice = 0;
   if(InpStopLoss > 0)
   {
      slPrice = (signal == SIGNAL_BUY) ? price - InpStopLoss * point
                                       : price + InpStopLoss * point;
   }
   if(InpTakeProfit > 0)
   {
      tpPrice = (signal == SIGNAL_BUY) ? price + InpTakeProfit * point
                                       : price - InpTakeProfit * point;
   }

   //--- Lot sizing
   double lots = CalculateLotSize(symbol, InpStopLoss);

   //--- Build request
   MqlTradeRequest req;
   BuildMarketOrder(req, symbol, orderType, lots, slPrice, tpPrice, magic, comment);

   //--- Send
   MqlTradeResult result;
   bool ok = SendOrder(req, result);

   if(ok)
      RiskRecordTrade();   // Update cooldown timestamp

   return ok;
}

#endif // TRADEEXEC_MQH
