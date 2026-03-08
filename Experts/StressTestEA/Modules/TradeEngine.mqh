//+------------------------------------------------------------------+
//|                                                TradeEngine.mqh   |
//|           StressTestEA – Order Send / Retry / Classify            |
//|                                    v2: async, latency, throttle   |
//|                                                                  |
//|  Builds MqlTradeRequest, pre-validates with OrderCheck, sends    |
//|  with OrderSend or OrderSendAsync, classifies retcodes, retries  |
//|  on safe transient errors with capped escalating backoff.         |
//|  Measures request latency with GetMicrosecondCount.               |
//|  Detects broker throttle and supports adaptive slowdown.          |
//+------------------------------------------------------------------+
#ifndef TRADEENGINE_MQH
#define TRADEENGINE_MQH

//===================================================================
// Trade result struct (v2) – returned from SendStressOrder
//===================================================================
struct StressOrderResult
{
   bool   success;       // true if fill confirmed
   uint   retcode;       // final retcode
   ulong  latencyUs;     // total latency in microseconds
   int    attempts;      // number of attempts used
   bool   throttled;     // true if TOO_MANY_REQUESTS was encountered
   ulong  order;         // order ticket (sync) or request_id (async)
};

//===================================================================
// Async pending order struct – maps request_id to send timestamp
//===================================================================
struct AsyncPending
{
   ulong  requestId;     // from MqlTradeResult.request_id
   ulong  sendTimeUs;    // GetMicrosecondCount at send time
   string dir;           // "BUY" or "SELL"
   double lots;          // volume
};

//--- Async pending queue (ring buffer style, fixed max)
#define ASYNC_PENDING_MAX 256
AsyncPending g_asyncPending[];
int          g_asyncPendingCount = 0;

//--- Throttle tracking (v2)
int    g_throttleHits      = 0;       // consecutive throttle hits
double g_adaptiveMultiplier = 1.0;    // pause multiplier (grows under throttle)
datetime g_lastThrottleReset = 0;     // last time throttle counter was reset

//===================================================================
// Is the retcode retryable?
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
// Escalating backoff with hard cap and adaptive multiplier
//===================================================================
int GetRetrySleepMs(uint retcode, int attempt)
{
   int baseMs = (retcode == TRADE_RETCODE_TOO_MANY_REQUESTS) ? 500 : 100;
   int ms     = baseMs * (attempt + 1);
   ms = (int)(ms * g_adaptiveMultiplier);
   if(ms > 5000) ms = 5000;
   return ms;
}

//===================================================================
// Update throttle state (v2)
//===================================================================
void OnThrottleDetected()
{
   g_throttleHits++;
   if(InpAdaptiveSlowdown && g_throttleHits >= InpThrottleThreshold)
   {
      g_adaptiveMultiplier *= InpSlowdownMultiplier;
      if(g_adaptiveMultiplier > 10.0)
         g_adaptiveMultiplier = 10.0;  // hard cap
      LogWarn("Engine", StringFormat(
         "Adaptive slowdown: throttleHits=%d multiplier=%.2f",
         g_throttleHits, g_adaptiveMultiplier));
   }
}

//--- Gradually recover adaptive multiplier when requests succeed
void OnThrottleRecovery()
{
   if(g_adaptiveMultiplier > 1.0)
   {
      g_adaptiveMultiplier = MathMax(1.0, g_adaptiveMultiplier * 0.9);
   }
   //--- Reset throttle counter every 30 seconds of clean operation
   if(TimeCurrent() - g_lastThrottleReset > 30)
   {
      if(g_throttleHits > 0)
      {
         g_throttleHits = MathMax(0, g_throttleHits - 1);
         g_lastThrottleReset = TimeCurrent();
      }
   }
}

//===================================================================
// Add async pending entry
//===================================================================
void AddAsyncPending(ulong requestId, ulong sendTimeUs, string dir, double lots)
{
   if(g_asyncPendingCount >= ASYNC_PENDING_MAX)
   {
      //--- Evict oldest (index 0)
      for(int i = 0; i < g_asyncPendingCount - 1; i++)
         g_asyncPending[i] = g_asyncPending[i + 1];
      g_asyncPendingCount--;
   }

   int idx = g_asyncPendingCount;
   if(ArraySize(g_asyncPending) <= idx)
      ArrayResize(g_asyncPending, idx + 64);

   g_asyncPending[idx].requestId  = requestId;
   g_asyncPending[idx].sendTimeUs = sendTimeUs;
   g_asyncPending[idx].dir        = dir;
   g_asyncPending[idx].lots       = lots;
   g_asyncPendingCount++;
}

//===================================================================
// Find and remove async pending by request_id; returns send time
//===================================================================
bool FindAsyncPending(ulong requestId, ulong &sendTimeUs, string &dir, double &lots)
{
   for(int i = 0; i < g_asyncPendingCount; i++)
   {
      if(g_asyncPending[i].requestId == requestId)
      {
         sendTimeUs = g_asyncPending[i].sendTimeUs;
         dir        = g_asyncPending[i].dir;
         lots       = g_asyncPending[i].lots;
         //--- Remove by shifting
         for(int j = i; j < g_asyncPendingCount - 1; j++)
            g_asyncPending[j] = g_asyncPending[j + 1];
         g_asyncPendingCount--;
         return true;
      }
   }
   return false;
}

//===================================================================
// InitTradeEngine – call in OnInit to set up v2 state
//===================================================================
void InitTradeEngine()
{
   g_asyncPendingCount  = 0;
   g_throttleHits       = 0;
   g_adaptiveMultiplier = 1.0;
   g_lastThrottleReset  = TimeCurrent();
   ArrayResize(g_asyncPending, 64);
}

//===================================================================
// SendStressOrder – build, validate, send with latency measurement
//===================================================================
//  Returns StressOrderResult with latency, attempt count, throttle.
//  Uses OrderSend (sync) or OrderSendAsync depending on InpUseAsync.
//===================================================================
StressOrderResult SendStressOrder(ENUM_ORDER_TYPE orderType)
{
   StressOrderResult result;
   ZeroMemory(result);

   string symbol = _Symbol;

   //--- Normalise lot size
   double lots = NormalizeLots(symbol, InpLotSize);
   if(lots <= 0)
   {
      LogWarn("Engine", "Lot size normalised to zero – check InpLotSize vs symbol min");
      result.retcode = TRADE_RETCODE_INVALID_VOLUME;
      return result;
   }

   string dir = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";

   //--- Build base request
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

   int maxRetries = (InpMaxRetries > 0) ? InpMaxRetries : 0;
   ulong startUs  = GetMicrosecondCount();

   //--- ASYNC PATH: single fire-and-forget
   if(InpUseAsync)
   {
      req.price = (orderType == ORDER_TYPE_BUY) ? GetAsk(symbol) : GetBid(symbol);
      if(req.price <= 0)
      {
         LogWarn("Engine", "Invalid price – market may be closed");
         LogCSVEx("REJECTED", symbol, dir, lots, 0, 0, 0, 1, "invalid_price");
         result.retcode = TRADE_RETCODE_PRICE_OFF;
         return result;
      }

      //--- OrderCheck for structural validation
      MqlTradeCheckResult checkRes;
      ZeroMemory(checkRes);
      if(!OrderCheck(req, checkRes))
      {
         LogCSVEx("REJECTED", symbol, dir, lots, req.price, checkRes.retcode,
                  0, 1, "ordercheck_" + RetcodeToString(checkRes.retcode));
         result.retcode = checkRes.retcode;
         return result;
      }

      LogTradeRequest(req);
      ulong sendUs = GetMicrosecondCount();

      MqlTradeResult res;
      ZeroMemory(res);

      bool sent = OrderSendAsync(req, res);
      ulong endUs = GetMicrosecondCount();
      ulong latUs = endUs - sendUs;

      result.latencyUs = latUs;
      result.attempts  = 1;

      if(sent && res.retcode == TRADE_RETCODE_PLACED)
      {
         result.success = true;
         result.retcode = res.retcode;
         result.order   = res.request_id;
         AddAsyncPending(res.request_id, sendUs, dir, lots);
         LogCSVEx("ASYNC_SENT", symbol, dir, lots, req.price,
                  res.retcode, latUs, 1,
                  StringFormat("req_id=%I64u", res.request_id));
         OnThrottleRecovery();
         return result;
      }

      //--- Async send failed immediately
      result.retcode = res.retcode;
      if(res.retcode == TRADE_RETCODE_TOO_MANY_REQUESTS)
      {
         result.throttled = true;
         OnThrottleDetected();
      }
      LogCSVEx("REJECTED", symbol, dir, lots, req.price,
               res.retcode, latUs, 1, RetcodeToString(res.retcode));
      return result;
   }

   //--- SYNC PATH: retry loop (0 to maxRetries inclusive)
   for(int attempt = 0; attempt <= maxRetries; attempt++)
   {
      req.price = (orderType == ORDER_TYPE_BUY) ? GetAsk(symbol) : GetBid(symbol);
      if(req.price <= 0)
      {
         LogWarn("Engine", "Invalid price – market may be closed");
         result.latencyUs = GetMicrosecondCount() - startUs;
         result.attempts  = attempt + 1;
         LogCSVEx("REJECTED", symbol, dir, lots, 0, 0,
                  result.latencyUs, result.attempts, "invalid_price");
         return result;
      }

      //--- OrderCheck on first attempt only
      if(attempt == 0)
      {
         MqlTradeCheckResult checkRes;
         ZeroMemory(checkRes);
         if(!OrderCheck(req, checkRes))
         {
            result.latencyUs = GetMicrosecondCount() - startUs;
            result.attempts  = 1;
            result.retcode   = checkRes.retcode;
            LogCSVEx("REJECTED", symbol, dir, lots, req.price,
                     checkRes.retcode, result.latencyUs, 1,
                     "ordercheck_" + RetcodeToString(checkRes.retcode));
            return result;
         }
      }

      //--- Log attempt
      LogCSVEx("ATTEMPT", symbol, dir, lots, req.price, 0,
               0, attempt + 1, StringFormat("try_%d", attempt + 1));

      //--- Send
      MqlTradeResult res;
      ZeroMemory(res);
      LogTradeRequest(req);

      ulong sendUs = GetMicrosecondCount();
      OrderSend(req, res);
      ulong endUs  = GetMicrosecondCount();

      LogTradeResult(res);

      uint retcode = res.retcode;

      //--- Success?
      if(retcode == TRADE_RETCODE_DONE
         || retcode == TRADE_RETCODE_DONE_PARTIAL
         || retcode == TRADE_RETCODE_PLACED)
      {
         result.success   = true;
         result.retcode   = retcode;
         result.latencyUs = endUs - startUs;
         result.attempts  = attempt + 1;
         result.order     = res.order;
         LogCSVEx("ACCEPTED", symbol, dir, lots, res.price, retcode,
                  endUs - sendUs, result.attempts,
                  StringFormat("ticket=%I64u", res.order));
         OnThrottleRecovery();
         return result;
      }

      //--- Throttle detection
      if(retcode == TRADE_RETCODE_TOO_MANY_REQUESTS)
      {
         result.throttled = true;
         OnThrottleDetected();
      }

      //--- Retryable and still have attempts left?
      if(IsRetryable(retcode) && attempt < maxRetries)
      {
         int sleepMs = GetRetrySleepMs(retcode, attempt);
         LogCSVEx("RETRY", symbol, dir, lots, req.price, retcode,
                  endUs - sendUs, attempt + 1,
                  StringFormat("try_%d_sleep_%dms", attempt + 1, sleepMs));
         Sleep(sleepMs);
         continue;
      }

      //--- Non-retryable or retries exhausted
      result.retcode   = retcode;
      result.latencyUs = endUs - startUs;
      result.attempts  = attempt + 1;
      LogCSVEx("REJECTED", symbol, dir, lots, req.price, retcode,
               result.latencyUs, result.attempts,
               RetcodeToString(retcode));
      return result;
   }

   result.latencyUs = GetMicrosecondCount() - startUs;
   return result;
}

#endif // TRADEENGINE_MQH
