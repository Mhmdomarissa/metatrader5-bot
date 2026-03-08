//+------------------------------------------------------------------+
//|                                              StressTestEA.mq5     |
//|  Rapid-fire market order stress test EA — DEMO / TEST ONLY.       |
//|                                                                  |
//|  Sends buy and sell market orders as frequently as possible       |
//|  within normal MT5 and broker rules.  Does NOT bypass broker      |
//|  protections, margin rules, stop-out, or trading permissions.     |
//|                                                                  |
//|  Features:                                                        |
//|   - Configurable mode: buy-only / sell-only / alternate / both    |
//|   - Timer + tick execution with optional burst mode               |
//|   - Position limits (total / buy / sell) + close-oldest option    |
//|   - Spread ceiling, free-margin guard, emergency equity stop      |
//|   - Capped retry with escalating backoff                          |
//|   - CSV logging for every trade event                             |
//|   - Re-entry lock to prevent duplicate sends on same event        |
//|   - Hedging and netting account support                           |
//+------------------------------------------------------------------+
#property copyright   "StressTestEA"
#property link        ""
#property version     "1.00"
#property description "Aggressive market order stress tester – DEMO ONLY"

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
//  Returns false when no valid direction is available (at limit).
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
         //--- Preferred direction from toggle; fallback to the other
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
         //--- Both available – balance by count, tie-break with toggle
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
//| Core trade cycle                                                  |
//+------------------------------------------------------------------+
//  Called from OnTick and/or OnTimer.  The re-entry lock (g_cycleRunning)
//  prevents overlapping execution when both sources fire close together.
//  Contains NO infinite loop – bounded by InpMaxReqPerCycle.
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
      LogAccountCSV();
      g_cycleRunning = false;
      return;
   }

   //--- Trading permission (lightweight, every cycle)
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
      //--- Re-check emergency each iteration (equity may have moved)
      if(CheckEmergencyStop()) { g_emergencyStop = true; break; }

      //--- Determine direction
      ENUM_ORDER_TYPE nextType;
      if(!GetNextOrderType(buyPos, sellPos, totalPos, nextType))
      {
         //--- At limit.  Try close-oldest if enabled.
         if(InpCloseOldest && totalPos > 0)
         {
            if(CloseOldestPosition(_Symbol, InpMagicNumber))
            {
               //--- Recount after close
               buyPos   = CountBuyPositions(_Symbol, InpMagicNumber);
               sellPos  = CountSellPositions(_Symbol, InpMagicNumber);
               totalPos = buyPos + sellPos;
               if(InpReEntryAfterClose)
                  continue;   // retry this iteration with new counts
            }
         }
         break;   // no room and close-oldest not enabled or failed
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

      //--- Send the order
      g_totalAttempts++;
      bool ok = SendStressOrder(nextType);

      if(ok)
      {
         g_totalAccepted++;
         if(nextType == ORDER_TYPE_BUY) buyPos++;
         else                           sellPos++;
         totalPos = buyPos + sellPos;
      }
      else
      {
         g_totalRejected++;
      }

      //--- Flip direction for ALTERNATE mode on every attempt
      if(InpTradeMode == MODE_ALTERNATE)
         g_alternateDir = 1 - g_alternateDir;

      //--- Inter-attempt pause (skipped in burst mode)
      if(!InpBurstMode && InpPauseBetweenMs > 0 && i < InpMaxReqPerCycle - 1)
         Sleep(InpPauseBetweenMs);
   }

   g_cycleRunning = false;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   LogInfo("Main", "====== StressTestEA v1.00 OnInit ======");
   LogInfo("Main", StringFormat("Symbol=%s Period=%s Magic=%I64d Mode=%s",
            _Symbol, EnumToString(_Period), InpMagicNumber, EnumToString(InpTradeMode)));
   LogInfo("Main", StringFormat("TickExec=%s TimerExec=%s TimerMs=%d MaxReq=%d Burst=%s",
            InpTickExecution ? "ON" : "OFF",
            InpTimerExecution ? "ON" : "OFF",
            InpTimerMs, InpMaxReqPerCycle,
            InpBurstMode ? "ON" : "OFF"));

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

   //--- Initialise state (restart-safe: counts live positions)
   g_startEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   g_emergencyStop = false;
   g_alternateDir  = 0;
   g_totalAttempts = 0;
   g_totalAccepted = 0;
   g_totalRejected = 0;
   g_lastSnapshot  = TimeCurrent();
   g_cycleRunning  = false;

   //--- Log any pre-existing positions
   int preExisting = CountTotalPositions(_Symbol, InpMagicNumber);
   if(preExisting > 0)
      LogInfo("Main", StringFormat("Found %d existing positions on startup (buy=%d sell=%d)",
               preExisting,
               CountBuyPositions(_Symbol, InpMagicNumber),
               CountSellPositions(_Symbol, InpMagicNumber)));

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

   //--- Initial account snapshot
   LogAccountCSV();

   g_initOK = true;
   LogInfo("Main", "====== StressTestEA ready – stress test armed ======");
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

   LogInfo("Main", StringFormat("OnDeinit – %s | attempts=%I64u accepted=%I64u rejected=%I64u",
            reasonStr, g_totalAttempts, g_totalAccepted, g_totalRejected));
   LogAccountCSV();
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

   //--- Periodic account snapshot and stats (~every 10 seconds)
   if(TimeCurrent() - g_lastSnapshot >= 10)
   {
      LogAccountCSV();
      LogInfo("Stats", StringFormat(
         "attempts=%I64u ok=%I64u fail=%I64u positions=%d equity=%.2f",
         g_totalAttempts, g_totalAccepted, g_totalRejected,
         CountTotalPositions(_Symbol, InpMagicNumber),
         AccountInfoDouble(ACCOUNT_EQUITY)));
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
   else if(trans.type == TRADE_TRANSACTION_REQUEST)
   {
      //--- Log non-success request results
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
   //--- For stress tests, report throughput as the optimisation criterion
   double trades = TesterStatistics(STAT_TRADES);
   LogInfo("Tester", StringFormat("OnTester: trades=%.0f attempts=%I64u accepted=%I64u",
            trades, g_totalAttempts, g_totalAccepted));
   return trades;
}

//+------------------------------------------------------------------+
