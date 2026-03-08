//+------------------------------------------------------------------+
//|                                              StressTestEA.mq5     |
//|  Rapid-fire market order stress test EA — DEMO / TEST ONLY.       |
//|                                                                  |
//|  v2 – High-frequency stress testing with:                         |
//|   - OrderSendAsync support (non-blocking order sending)           |
//|   - Microsecond latency measurement per request                   |
//|   - Broker throttle detection & adaptive slowdown                 |
//|   - RPS (requests per second) rolling window stats                |
//|   - Rejection stats by retcode histogram                          |
//|   - Rolling throughput metrics with CSV export                    |
//|   - Auto-close on margin critical (stop-out proximity)            |
//|   - Stop-out proximity alerts via ACCOUNT_MARGIN_SO_CALL/SO_SO    |
//|   - Phone notification hooks via SendNotification                 |
//|   - Enhanced CSV with latency_us and attempt_count fields         |
//|   - Terminal-safe concurrency (re-entry lock)                     |
//|                                                                  |
//|  Does NOT bypass broker protections, margin rules, stop-out,      |
//|  or trading permissions.                                          |
//+------------------------------------------------------------------+
#property copyright   "StressTestEA"
#property link        ""
#property version     "2.00"
#property description "High-frequency market order stress tester v2 – DEMO ONLY"

//===================================================================
// INCLUDES – order matters: Config → Logger → SymbolInfo →
//            PositionManager → TradeEngine
//===================================================================
#include "Modules/Config.mqh"
#include "Modules/Logger.mqh"
#include "Modules/SymbolInfo.mqh"
#include "Modules/PositionManager.mqh"
#include "Modules/TradeEngine.mqh"

//===================================================================
// GLOBALS
//===================================================================
bool     g_initOK        = false;
bool     g_cycleRunning  = false;    // re-entry lock
bool     g_emergencyStop = false;
double   g_startEquity   = 0;
int      g_alternateDir  = 0;       // 0 = BUY next, 1 = SELL next
ulong    g_totalAttempts = 0;
ulong    g_totalAccepted = 0;
ulong    g_totalRejected = 0;
datetime g_lastSnapshot  = 0;
datetime g_lastStats     = 0;

//--- v2: RPS rolling window
#define  RPS_WINDOW_MAX   3600      // max 1 hour of second-by-second counts
ulong    g_rpsTimestamps[];         // timestamp of each accepted order
int      g_rpsHead       = 0;
int      g_rpsSize       = 0;

//--- v2: Latency accumulator for avg calculation
ulong    g_totalLatencyUs    = 0;
ulong    g_latencySampleCount = 0;

//--- v2: Rejection histogram (retcode → count)
#define  REJECT_MAP_SIZE 64
uint     g_rejectRetcodes[];
ulong    g_rejectCounts[];
int      g_rejectMapUsed = 0;

//--- v2: Margin notification cooldown
datetime g_lastMarginNotify = 0;

//+------------------------------------------------------------------+
//| RPS window – record an accepted order                             |
//+------------------------------------------------------------------+
void RecordRPSEvent()
{
   datetime now = TimeCurrent();
   if(g_rpsSize >= ArraySize(g_rpsTimestamps))
   {
      int newSize = MathMin(g_rpsSize + 256, RPS_WINDOW_MAX);
      if(newSize <= ArraySize(g_rpsTimestamps))
      {
         //--- Full – evict oldest
         g_rpsHead = (g_rpsHead + 1) % ArraySize(g_rpsTimestamps);
         g_rpsSize--;
      }
      else
         ArrayResize(g_rpsTimestamps, newSize);
   }
   int idx = (g_rpsHead + g_rpsSize) % ArraySize(g_rpsTimestamps);
   g_rpsTimestamps[idx] = now;
   g_rpsSize++;
}

//+------------------------------------------------------------------+
//| RPS window – compute RPS over the configured window               |
//+------------------------------------------------------------------+
double ComputeRPS()
{
   if(g_rpsSize == 0) return 0;
   datetime now    = TimeCurrent();
   datetime cutoff = now - InpRPSWindowSec;

   //--- Evict old entries from head
   while(g_rpsSize > 0)
   {
      int headIdx = g_rpsHead % ArraySize(g_rpsTimestamps);
      if(g_rpsTimestamps[headIdx] < cutoff)
      {
         g_rpsHead = (g_rpsHead + 1) % ArraySize(g_rpsTimestamps);
         g_rpsSize--;
      }
      else
         break;
   }

   if(g_rpsSize == 0) return 0;
   double windowSec = (double)InpRPSWindowSec;
   if(windowSec <= 0) windowSec = 1;
   return (double)g_rpsSize / windowSec;
}

//+------------------------------------------------------------------+
//| Rejection histogram – record a rejection                          |
//+------------------------------------------------------------------+
void RecordRejection(uint retcode)
{
   //--- Search existing
   for(int i = 0; i < g_rejectMapUsed; i++)
   {
      if(g_rejectRetcodes[i] == retcode)
      {
         g_rejectCounts[i]++;
         return;
      }
   }
   //--- Add new entry
   if(g_rejectMapUsed < REJECT_MAP_SIZE)
   {
      if(ArraySize(g_rejectRetcodes) <= g_rejectMapUsed)
      {
         ArrayResize(g_rejectRetcodes, g_rejectMapUsed + 16);
         ArrayResize(g_rejectCounts,   g_rejectMapUsed + 16);
      }
      g_rejectRetcodes[g_rejectMapUsed] = retcode;
      g_rejectCounts[g_rejectMapUsed]   = 1;
      g_rejectMapUsed++;
   }
}

//+------------------------------------------------------------------+
//| Log rejection histogram to CSV                                    |
//+------------------------------------------------------------------+
void LogRejectionHistogram()
{
   for(int i = 0; i < g_rejectMapUsed; i++)
   {
      if(g_rejectCounts[i] > 0)
         LogRejectionCSV(g_rejectRetcodes[i], g_rejectCounts[i]);
   }
}

//+------------------------------------------------------------------+
//| Compute average latency                                           |
//+------------------------------------------------------------------+
double ComputeAvgLatencyUs()
{
   if(g_latencySampleCount == 0) return 0;
   return (double)g_totalLatencyUs / (double)g_latencySampleCount;
}

//+------------------------------------------------------------------+
//| Margin proximity check with optional notification (v2)            |
//+------------------------------------------------------------------+
void CheckMarginProximity()
{
   if(!IsMarginCritical(InpMarginWarningPct)) return;

   double mlevel = GetMarginLevel();
   double soCall = GetSOCallLevel();
   double soSO   = GetSOStopOutLevel();
   double prox   = MarginProximityToSO();

   LogWarn("Margin", StringFormat(
      "MARGIN WARNING: level=%.2f%% SO_CALL=%.2f%% SO_SO=%.2f%% proximity=%.2f%%",
      mlevel, soCall, soSO, prox));

   //--- Auto-close if enabled
   if(InpMarginAutoClose)
   {
      int closed = 0;
      //--- Close up to 3 positions per check to avoid blocking too long
      for(int i = 0; i < 3; i++)
      {
         if(!IsMarginCritical(InpMarginWarningPct)) break;
         if(CloseOldestIfMarginCritical(_Symbol, InpMagicNumber, InpMarginWarningPct))
            closed++;
         else
            break;
      }
      if(closed > 0)
         LogWarn("Margin", StringFormat("Auto-closed %d positions for margin relief", closed));
   }

   //--- Phone notification (cooldown: max once per 60 seconds)
   if(InpNotifyOnCritical)
   {
      if(TimeCurrent() - g_lastMarginNotify >= 60)
      {
         string msg = StringFormat(
            "StressTestEA MARGIN ALERT: %.1f%% (SO=%.1f%%) on %s",
            mlevel, soSO, _Symbol);
         SendNotification(msg);
         g_lastMarginNotify = TimeCurrent();
         LogInfo("Margin", "Push notification sent: " + msg);
      }
   }
}

//+------------------------------------------------------------------+
//| Periodic stats reporting (v2)                                     |
//+------------------------------------------------------------------+
void ReportStats()
{
   double rps            = ComputeRPS();
   double avgLatUs       = ComputeAvgLatencyUs();
   int    throttleCount  = g_throttleHits;
   double adaptiveMult   = g_adaptiveMultiplier;
   int    totalPos       = CountTotalPositions(_Symbol, InpMagicNumber);
   double equity         = AccountInfoDouble(ACCOUNT_EQUITY);
   double marginLevel    = GetMarginLevel();

   //--- Console log
   LogInfo("Stats", StringFormat(
      "attempts=%I64u ok=%I64u fail=%I64u RPS=%.2f avgLat=%.0fus "
      "throttle=%d adapt=%.2f pos=%d equity=%.2f mlevel=%.2f%%",
      g_totalAttempts, g_totalAccepted, g_totalRejected,
      rps, avgLatUs, throttleCount, adaptiveMult,
      totalPos, equity, marginLevel));

   //--- CSV stats
   LogStatsCSV(g_totalAttempts, g_totalAccepted, g_totalRejected,
               rps, avgLatUs, throttleCount, adaptiveMult);

   //--- Extended account snapshot with SO levels
   LogAccountCSVEx();

   //--- Rejection histogram
   LogRejectionHistogram();
}

//+------------------------------------------------------------------+
//| Input validation                                                  |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpLotSize <= 0)
   { LogError("Main", "Lot size must be > 0"); return false; }

   if(InpMaxOpenTotal <= 0)
   { LogError("Main", "Max total positions must be > 0"); return false; }

   if(InpMaxOpenBuy < 0 || InpMaxOpenSell < 0)
   { LogError("Main", "Max buy / sell must be >= 0"); return false; }

   if(InpMaxReqPerCycle <= 0)
   { LogError("Main", "Max requests per cycle must be > 0"); return false; }

   if(InpTimerExecution && InpTimerMs <= 0)
   { LogError("Main", "Timer ms must be > 0 when timer execution is enabled"); return false; }

   if(InpMaxRetries < 0)
   { LogError("Main", "Max retries must be >= 0"); return false; }

   if(InpSlippage < 0)
   { LogError("Main", "Slippage must be >= 0"); return false; }

   if(InpMinFreeMargin < 0)
   { LogError("Main", "Min free margin must be >= 0"); return false; }

   if(InpEmergencyStopPct < 0 || InpEmergencyStopPct > 100)
   { LogError("Main", "Emergency stop % must be 0–100"); return false; }

   if(InpTradeMode == MODE_BUY_ONLY && InpMaxOpenBuy <= 0)
   { LogError("Main", "Buy-only mode but MaxOpenBuy = 0"); return false; }

   if(InpTradeMode == MODE_SELL_ONLY && InpMaxOpenSell <= 0)
   { LogError("Main", "Sell-only mode but MaxOpenSell = 0"); return false; }

   if(!InpTickExecution && !InpTimerExecution)
      LogWarn("Main", "WARNING: Both tick and timer execution disabled – EA will NOT trade");

   //--- v2 validations
   if(InpThrottleThreshold <= 0)
   { LogError("Main", "Throttle threshold must be > 0"); return false; }

   if(InpSlowdownMultiplier < 1.0)
   { LogError("Main", "Slowdown multiplier must be >= 1.0"); return false; }

   if(InpMarginWarningPct < 0)
   { LogError("Main", "Margin warning % must be >= 0"); return false; }

   if(InpStatsIntervalSec <= 0)
   { LogError("Main", "Stats interval must be > 0 seconds"); return false; }

   if(InpRPSWindowSec <= 0)
   { LogError("Main", "RPS window must be > 0 seconds"); return false; }

   return true;
}

//+------------------------------------------------------------------+
//| Emergency stop check                                              |
//+------------------------------------------------------------------+
bool CheckEmergencyStop()
{
   if(InpEmergencyStopPct <= 0 || g_startEquity <= 0) return false;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dropPct = (g_startEquity - equity) / g_startEquity * 100.0;
   return (dropPct >= InpEmergencyStopPct);
}

//+------------------------------------------------------------------+
//| Determine next order direction                                    |
//+------------------------------------------------------------------+
bool GetNextOrderType(int buyPos, int sellPos, int totalPos,
                      ENUM_ORDER_TYPE &orderType)
{
   if(totalPos >= InpMaxOpenTotal) return false;

   bool canBuy  = (buyPos  < InpMaxOpenBuy);
   bool canSell = (sellPos < InpMaxOpenSell);

   switch(InpTradeMode)
   {
      case MODE_BUY_ONLY:
         if(!canBuy) return false;
         orderType = ORDER_TYPE_BUY;
         return true;

      case MODE_SELL_ONLY:
         if(!canSell) return false;
         orderType = ORDER_TYPE_SELL;
         return true;

      case MODE_ALTERNATE:
         if(g_alternateDir == 0)
         {
            if(canBuy)  { orderType = ORDER_TYPE_BUY;  return true; }
            if(canSell) { orderType = ORDER_TYPE_SELL; return true; }
         }
         else
         {
            if(canSell) { orderType = ORDER_TYPE_SELL; return true; }
            if(canBuy)  { orderType = ORDER_TYPE_BUY;  return true; }
         }
         return false;

      case MODE_BOTH:
      {
         if(!canBuy && !canSell) return false;
         if(canBuy  && !canSell) { orderType = ORDER_TYPE_BUY;  return true; }
         if(!canBuy && canSell)  { orderType = ORDER_TYPE_SELL; return true; }
         if(buyPos < sellPos)       orderType = ORDER_TYPE_BUY;
         else if(sellPos < buyPos)  orderType = ORDER_TYPE_SELL;
         else
         {
            orderType = (g_alternateDir == 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            g_alternateDir = 1 - g_alternateDir;
         }
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Core trade cycle (v2)                                             |
//+------------------------------------------------------------------+
void TradeCycle()
{
   if(g_cycleRunning)  return;          // re-entry guard
   if(g_emergencyStop) return;
   g_cycleRunning = true;

   //--- Emergency equity check
   if(CheckEmergencyStop())
   {
      g_emergencyStop = true;
      LogError("Main", StringFormat(
         "EMERGENCY STOP – equity dropped >= %.1f%% from start (%.2f -> %.2f)",
         InpEmergencyStopPct, g_startEquity, AccountInfoDouble(ACCOUNT_EQUITY)));
      LogAccountCSVEx();
      if(InpNotifyOnCritical)
         SendNotification(StringFormat("StressTestEA EMERGENCY STOP equity=%.2f",
                          AccountInfoDouble(ACCOUNT_EQUITY)));
      g_cycleRunning = false;
      return;
   }

   //--- Margin proximity check (v2 – before opening new positions)
   CheckMarginProximity();

   //--- Trading permission
   if(!IsTradingAllowedNow(_Symbol))
   {
      g_cycleRunning = false;
      return;
   }

   //--- Count positions once per cycle
   int buyPos   = CountBuyPositions(_Symbol, InpMagicNumber);
   int sellPos  = CountSellPositions(_Symbol, InpMagicNumber);
   int totalPos = buyPos + sellPos;

   //--- Order loop (bounded by InpMaxReqPerCycle)
   for(int i = 0; i < InpMaxReqPerCycle; i++)
   {
      //--- Re-check emergency each iteration
      if(CheckEmergencyStop()) { g_emergencyStop = true; break; }

      //--- Determine direction
      ENUM_ORDER_TYPE nextType;
      if(!GetNextOrderType(buyPos, sellPos, totalPos, nextType))
      {
         //--- At limit. Try close-oldest if enabled.
         if(InpCloseOldest && totalPos > 0)
         {
            if(CloseOldestPosition(_Symbol, InpMagicNumber))
            {
               buyPos   = CountBuyPositions(_Symbol, InpMagicNumber);
               sellPos  = CountSellPositions(_Symbol, InpMagicNumber);
               totalPos = buyPos + sellPos;
               if(InpReEntryAfterClose)
                  continue;
            }
         }
         break;
      }

      //--- Spread guard
      if(InpMaxSpreadPts > 0)
      {
         int spread = GetSpreadPoints(_Symbol);
         if(spread > InpMaxSpreadPts)
         {
            LogDebug("Main", StringFormat("Spread %d > %d – cycle paused", spread, InpMaxSpreadPts));
            break;
         }
      }

      //--- Free margin guard
      double freeMgn = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(freeMgn < InpMinFreeMargin)
      {
         LogDebug("Main", StringFormat("FreeMargin %.2f < %.2f – cycle paused", freeMgn, InpMinFreeMargin));
         break;
      }

      //--- Send the order (v2 – returns struct with latency)
      g_totalAttempts++;
      StressOrderResult res = SendStressOrder(nextType);

      if(res.success)
      {
         g_totalAccepted++;
         if(nextType == ORDER_TYPE_BUY) buyPos++;
         else                           sellPos++;
         totalPos = buyPos + sellPos;
         RecordRPSEvent();
      }
      else
      {
         g_totalRejected++;
         if(res.retcode != 0)
            RecordRejection(res.retcode);
      }

      //--- Accumulate latency stats
      if(res.latencyUs > 0)
      {
         g_totalLatencyUs     += res.latencyUs;
         g_latencySampleCount += 1;
      }

      //--- Flip direction for ALTERNATE mode
      if(InpTradeMode == MODE_ALTERNATE)
         g_alternateDir = 1 - g_alternateDir;

      //--- Inter-attempt pause (adjusted by adaptive multiplier in v2)
      if(!InpBurstMode && InpPauseBetweenMs > 0 && i < InpMaxReqPerCycle - 1)
      {
         int pauseMs = (int)(InpPauseBetweenMs * g_adaptiveMultiplier);
         if(pauseMs > 0)
            Sleep(pauseMs);
      }
   }

   g_cycleRunning = false;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   LogInfo("Main", "====== StressTestEA v2.00 OnInit ======");
   LogInfo("Main", StringFormat("Symbol=%s Period=%s Magic=%I64d Mode=%s",
            _Symbol, EnumToString(_Period), InpMagicNumber, EnumToString(InpTradeMode)));
   LogInfo("Main", StringFormat("TickExec=%s TimerExec=%s TimerMs=%d MaxReq=%d Burst=%s",
            InpTickExecution ? "ON" : "OFF",
            InpTimerExecution ? "ON" : "OFF",
            InpTimerMs, InpMaxReqPerCycle,
            InpBurstMode ? "ON" : "OFF"));
   LogInfo("Main", StringFormat("Async=%s Adaptive=%s MarginAutoClose=%s Notify=%s",
            InpUseAsync ? "ON" : "OFF",
            InpAdaptiveSlowdown ? "ON" : "OFF",
            InpMarginAutoClose ? "ON" : "OFF",
            InpNotifyOnCritical ? "ON" : "OFF"));

   //--- Validate inputs
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   //--- Cache symbol properties
   if(!CacheSymbolInfo(_Symbol))
      return INIT_FAILED;

   //--- Permissions
   if(!IsAlgoTradingAllowed())
   {
      LogError("Main", "Algo trading not allowed – press AutoTrading button or check EA properties");
      return INIT_FAILED;
   }

   //--- Initialise TradeEngine v2 state
   InitTradeEngine();

   //--- Initialise state (restart-safe: counts live positions)
   g_startEquity       = AccountInfoDouble(ACCOUNT_EQUITY);
   g_emergencyStop     = false;
   g_alternateDir      = 0;
   g_totalAttempts     = 0;
   g_totalAccepted     = 0;
   g_totalRejected     = 0;
   g_lastSnapshot      = TimeCurrent();
   g_lastStats         = TimeCurrent();
   g_cycleRunning      = false;
   g_lastMarginNotify  = 0;

   //--- v2: Init RPS window
   ArrayResize(g_rpsTimestamps, 256);
   g_rpsHead = 0;
   g_rpsSize = 0;

   //--- v2: Init latency accumulators
   g_totalLatencyUs     = 0;
   g_latencySampleCount = 0;

   //--- v2: Init rejection histogram
   ArrayResize(g_rejectRetcodes, 16);
   ArrayResize(g_rejectCounts, 16);
   g_rejectMapUsed = 0;

   //--- Log any pre-existing positions
   int preExisting = CountTotalPositions(_Symbol, InpMagicNumber);
   if(preExisting > 0)
      LogInfo("Main", StringFormat("Found %d existing positions on startup (buy=%d sell=%d)",
               preExisting,
               CountBuyPositions(_Symbol, InpMagicNumber),
               CountSellPositions(_Symbol, InpMagicNumber)));

   //--- Log broker SO levels
   LogInfo("Main", StringFormat("Broker SO_CALL=%.2f%% SO_STOPOUT=%.2f%%",
            GetSOCallLevel(), GetSOStopOutLevel()));

   //--- Timer
   if(InpTimerExecution && InpTimerMs > 0)
   {
      if(!EventSetMillisecondTimer(InpTimerMs))
      {
         LogWarn("Main", "EventSetMillisecondTimer failed – using 1-second fallback");
         EventSetTimer(1);
      }
      else
         LogInfo("Main", StringFormat("Millisecond timer set: %d ms", InpTimerMs));
   }

   //--- Initial account snapshot (v2 extended)
   LogAccountCSVEx();

   g_initOK = true;
   LogInfo("Main", "====== StressTestEA v2.00 ready – stress test armed ======");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   string reasonStr;
   switch(reason)
   {
      case REASON_PROGRAM:     reasonStr = "Program ended";              break;
      case REASON_REMOVE:      reasonStr = "EA removed from chart";      break;
      case REASON_RECOMPILE:   reasonStr = "Recompiled";                 break;
      case REASON_CHARTCHANGE: reasonStr = "Chart symbol/period changed"; break;
      case REASON_CHARTCLOSE:  reasonStr = "Chart closed";               break;
      case REASON_PARAMETERS:  reasonStr = "Inputs changed";             break;
      case REASON_ACCOUNT:     reasonStr = "Account changed";            break;
      case REASON_TEMPLATE:    reasonStr = "Template applied";           break;
      case REASON_INITFAILED:  reasonStr = "Init failed";                break;
      case REASON_CLOSE:       reasonStr = "Terminal closed";            break;
      default:                 reasonStr = "Unknown(" + IntegerToString(reason) + ")"; break;
   }

   //--- Final stats
   double rps       = ComputeRPS();
   double avgLatUs  = ComputeAvgLatencyUs();

   LogInfo("Main", StringFormat(
      "OnDeinit – %s | attempts=%I64u accepted=%I64u rejected=%I64u "
      "RPS=%.2f avgLat=%.0fus throttle=%d adapt=%.2f",
      reasonStr, g_totalAttempts, g_totalAccepted, g_totalRejected,
      rps, avgLatUs, g_throttleHits, g_adaptiveMultiplier));

   //--- Final CSV snapshots
   ReportStats();
   LogAccountCSVEx();
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_initOK) return;
   if(!InpTickExecution) return;
   TradeCycle();
}

//+------------------------------------------------------------------+
//| OnTimer                                                           |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_initOK) return;

   //--- Periodic stats reporting (every InpStatsIntervalSec)
   if(TimeCurrent() - g_lastStats >= InpStatsIntervalSec)
   {
      ReportStats();
      g_lastStats = TimeCurrent();
   }

   //--- Periodic account snapshot (every 10 seconds minimum)
   if(TimeCurrent() - g_lastSnapshot >= 10)
   {
      LogAccountCSVEx();
      g_lastSnapshot = TimeCurrent();
   }

   if(!InpTimerExecution) return;
   TradeCycle();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction – track server-side trade events               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   //--- v2: Resolve async pending orders
   if(trans.type == TRADE_TRANSACTION_REQUEST)
   {
      ulong sendTimeUs = 0;
      string dir = "";
      double lots = 0;

      if(FindAsyncPending(result.request_id, sendTimeUs, dir, lots))
      {
         ulong nowUs   = GetMicrosecondCount();
         ulong latUs   = nowUs - sendTimeUs;

         if(result.retcode == TRADE_RETCODE_DONE
            || result.retcode == TRADE_RETCODE_DONE_PARTIAL
            || result.retcode == TRADE_RETCODE_PLACED)
         {
            LogCSVEx("ASYNC_OK", _Symbol, dir, lots, result.price,
                     result.retcode, latUs, 1,
                     StringFormat("req_id=%I64u ticket=%I64u", result.request_id, result.order));

            //--- Accumulate latency
            g_totalLatencyUs     += latUs;
            g_latencySampleCount += 1;
         }
         else
         {
            LogCSVEx("ASYNC_FAIL", _Symbol, dir, lots, 0,
                     result.retcode, latUs, 1,
                     StringFormat("req_id=%I64u %s", result.request_id,
                                  RetcodeToString(result.retcode)));
            RecordRejection(result.retcode);

            if(result.retcode == TRADE_RETCODE_TOO_MANY_REQUESTS)
               OnThrottleDetected();
         }
      }
      else
      {
         //--- Non-async or unknown request – log failures
         if(result.retcode != TRADE_RETCODE_DONE
            && result.retcode != TRADE_RETCODE_DONE_PARTIAL
            && result.retcode != TRADE_RETCODE_PLACED
            && result.retcode != 0)
         {
            LogDebug("TradeTxn", StringFormat("REQUEST retcode=%u (%s)",
                      result.retcode, RetcodeToString(result.retcode)));
         }
      }
   }

   //--- Track deal additions (same as v1 but with debug logging)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(!HistoryDealSelect(trans.deal)) return;

      long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      if(magic != InpMagicNumber) return;

      long   entry    = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      long   dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      double volume   = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
      double price    = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      double profit   = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      string dir      = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";

      string event;
      if(entry == DEAL_ENTRY_IN)        event = "DEAL_IN";
      else if(entry == DEAL_ENTRY_OUT)  event = "DEAL_OUT";
      else                              event = "DEAL_INOUT";

      LogDebug("TradeTxn", StringFormat("%s %s %.4f @ %.5f pnl=%.2f deal=%I64u",
                event, dir, volume, price, profit, trans.deal));
   }
}

//+------------------------------------------------------------------+
//| OnTrade                                                           |
//+------------------------------------------------------------------+
void OnTrade()
{
   LogDebug("Main", StringFormat("OnTrade – positions=%d orders=%d",
             PositionsTotal(), OrdersTotal()));
}

//+------------------------------------------------------------------+
//| OnTester – custom criterion for strategy tester                   |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double rps    = ComputeRPS();
   double avgLat = ComputeAvgLatencyUs();

   LogInfo("Tester", StringFormat(
      "OnTester: trades=%.0f attempts=%I64u accepted=%I64u RPS=%.2f avgLat=%.0fus",
      trades, g_totalAttempts, g_totalAccepted, rps, avgLat));

   //--- Report final stats to CSV
   ReportStats();

   return trades;
}

//+------------------------------------------------------------------+
