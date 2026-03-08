//+------------------------------------------------------------------+
//|                                                TradeEngine.mqh   |
//|           StressTestEA – Order Send / Retry / Classify            |
//|                                                                  |
//|  Builds MqlTradeRequest, pre-validates with OrderCheck, sends    |
//|  with OrderSend, classifies retcodes, and retries only on safe   |
//|  transient errors (requote, timeout, throttle) with capped       |
//|  escalating backoff.  No infinite loops.                          |
//+------------------------------------------------------------------+
#ifndef TRADEENGINE_MQH
#define TRADEENGINE_MQH

//===================================================================
// Is the retcode retryable?
//===================================================================
//  Safe transients only: requote, price move, timeout/connection,
//  and temporary throttle (TOO_MANY_REQUESTS).
//===================================================================
bool IsRetryable(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return true;
      default:
         return false;
   }
}

//===================================================================
// Escalating backoff with hard cap
//===================================================================
//  TOO_MANY_REQUESTS gets a longer base (500ms) since the broker
//  is actively throttling.  All other retryables use 100ms base.
//  Cap at 2000ms to avoid freezing the terminal.
//===================================================================
int GetRetrySleepMs(uint retcode, int attempt)
{
   int baseMs = (retcode == TRADE_RETCODE_TOO_MANY_REQUESTS) ? 500 : 100;
   int ms     = baseMs * (attempt + 1);
   if(ms > 2000) ms = 2000;
   return ms;
}

//===================================================================
// SendStressOrder – build, validate, send a market order with retry
//===================================================================
//  1. Normalise volume
//  2. Build MqlTradeRequest
//  3. OrderCheck on first attempt (structural pre-validation)
//  4. OrderSend in retry loop (capped by InpMaxRetries)
//  5. CSV-log every step: ATTEMPT → ACCEPTED | RETRY | REJECTED
//
//  Returns true only if the trade server confirmed a fill.
//===================================================================
bool SendStressOrder(ENUM_ORDER_TYPE orderType)
{
   string symbol = _Symbol;

   //--- Normalise lot size
   double lots = NormalizeLots(symbol, InpLotSize);
   if(lots <= 0)
   {
      LogWarn("Engine", "Lot size normalised to zero – check InpLotSize vs symbol min");
      return false;
   }

   string dir = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";

   //--- Build base request (price refreshed each attempt)
   MqlTradeRequest req;
   ZeroMemory(req);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.volume       = lots;
   req.type         = orderType;
   req.magic        = InpMagicNumber;
   req.comment      = InpTradeComment;
   req.deviation    = (uint)InpSlippage;
   req.type_filling = DetectFillingMode(symbol);

   //--- Retry loop (0 to maxRetries inclusive = maxRetries+1 total attempts)
   int maxRetries = (InpMaxRetries > 0) ? InpMaxRetries : 0;

   for(int attempt = 0; attempt <= maxRetries; attempt++)
   {
      //--- Refresh price every attempt
      req.price = (orderType == ORDER_TYPE_BUY) ? GetAsk(symbol) : GetBid(symbol);
      if(req.price <= 0)
      {
         LogWarn("Engine", "Invalid price – market may be closed");
         LogCSV("REJECTED", symbol, dir, lots, 0, 0, "invalid_price");
         return false;
      }

      //--- OrderCheck on first attempt only (speed optimisation)
      if(attempt == 0)
      {
         MqlTradeCheckResult checkRes;
         ZeroMemory(checkRes);
         if(!OrderCheck(req, checkRes))
         {
            LogDebug("Engine", StringFormat("OrderCheck fail: %u (%s) %s",
                      checkRes.retcode, RetcodeToString(checkRes.retcode),
                      checkRes.comment));
            LogCSV("REJECTED", symbol, dir, lots, req.price, checkRes.retcode,
                   "ordercheck_" + RetcodeToString(checkRes.retcode));
            return false;
         }
      }

      //--- Log the attempt
      LogCSV("ATTEMPT", symbol, dir, lots, req.price, 0,
             StringFormat("try_%d", attempt + 1));

      //--- Send
      MqlTradeResult res;
      ZeroMemory(res);
      LogTradeRequest(req);

      OrderSend(req, res);

      LogTradeResult(res);

      uint retcode = res.retcode;

      //--- Success?
      if(retcode == TRADE_RETCODE_DONE
         || retcode == TRADE_RETCODE_DONE_PARTIAL
         || retcode == TRADE_RETCODE_PLACED)
      {
         LogDebug("Engine", StringFormat("%s %.4f @ %.5f ticket=%I64u rc=%u",
                   dir, lots, res.price, res.order, retcode));
         LogCSV("ACCEPTED", symbol, dir, lots, res.price, retcode,
                StringFormat("ticket=%I64u", res.order));
         return true;
      }

      //--- Retryable and still have attempts left?
      if(IsRetryable(retcode) && attempt < maxRetries)
      {
         int sleepMs = GetRetrySleepMs(retcode, attempt);
         LogCSV("RETRY", symbol, dir, lots, req.price, retcode,
                StringFormat("try_%d_sleep_%dms", attempt + 1, sleepMs));
         Sleep(sleepMs);
         continue;
      }

      //--- Non-retryable or retries exhausted
      LogDebug("Engine", StringFormat("Order FAIL: %s rc=%u (%s)",
                dir, retcode, RetcodeToString(retcode)));
      LogCSV("REJECTED", symbol, dir, lots, req.price, retcode,
             RetcodeToString(retcode));
      return false;
   }

   return false;
}

#endif // TRADEENGINE_MQH
