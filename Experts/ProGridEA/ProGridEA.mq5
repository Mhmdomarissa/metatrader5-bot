//+------------------------------------------------------------------+
//|                                                  ProGridEA.mq5    |
//|                        ProGridEA v2 – Main Expert Advisor         |
//|                          Copyright 2026                           |
//|                                                                  |
//|  A production-ready MT5 EA framework with:                       |
//|   • MA-crossover strategy (pluggable)                            |
//|   • ATR-based or fixed SL/TP (v2)                                |
//|   • Full risk management suite (12 pre-trade gates)              |
//|   • Order validation (OrderCheck → OrderSend)                    |
//|   • Trailing stop & break-even                                   |
//|   • Session, spread, margin, equity safeguards                   |
//|   • Buy/sell enable flags (v2)                                   |
//|   • Daily max trades & loss cooldown (v2)                        |
//|   • CSV-style structured logging (v2)                            |
//|   • Clean lifecycle (OnInit/OnDeinit/OnTick/OnTimer/OnTrade…)    |
//+------------------------------------------------------------------+
#property copyright   "ProGridEA"
#property link        ""
#property version     "2.00"
#property description "Modular MT5 Expert Advisor framework – v2"

//===================================================================
// INCLUDES – order matters: Config first, then Logger, then Utils,
// then the modules that depend on them.
//===================================================================
#include "Modules/Config.mqh"
#include "Modules/Logger.mqh"
#include "Modules/Utils.mqh"
#include "Modules/SignalEngine.mqh"
#include "Modules/RiskManager.mqh"
#include "Modules/TradeExec.mqh"
#include "Modules/PositionMgr.mqh"

//===================================================================
// GLOBALS
//===================================================================
datetime g_lastBarTime = 0;   // For one-trade-per-bar guard
bool     g_initOK      = false;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   LogInfo("Main", "====== ProGridEA v2 OnInit ======");
   LogInfo("Main", StringFormat("Symbol=%s  Period=%s  Magic=%I64d",
            _Symbol, EnumToString(_Period), InpMagicNumber));

   //--- Validate critical inputs ─────────────────────────────────
   // Strategy
   if(InpFastMA <= 0 || InpSlowMA <= 0)
   {
      LogError("Main", "MA periods must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFastMA >= InpSlowMA)
   {
      LogError("Main", "FastMA must be < SlowMA – check inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Buy/sell flags (v2) – at least one must be enabled
   if(!InpEnableBuy && !InpEnableSell)
   {
      LogError("Main", "At least one of Enable Buy / Enable Sell must be true");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Lot sizing
   if(InpFixedLots <= 0 && InpLotMode == LOT_MODE_FIXED)
   {
      LogError("Main", "Fixed lot size must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLotMode == LOT_MODE_RISK && InpRiskPercent <= 0)
   {
      LogError("Main", "Risk percent must be > 0 in risk mode");
      return INIT_PARAMETERS_INCORRECT;
   }

   // SL/TP mode (v2)
   if(InpSLTPMode == SLTP_ATR)
   {
      if(InpATRPeriod <= 0)
      {
         LogError("Main", "ATR period must be > 0 in ATR mode");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpATRMultSL <= 0 || InpATRMultTP <= 0)
      {
         LogError("Main", "ATR multipliers must be > 0 in ATR mode");
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   // Session
   if(InpUseSessionFilter && (InpSessionStartHour < 0 || InpSessionStartHour > 23
                           || InpSessionEndHour < 0   || InpSessionEndHour > 23))
   {
      LogError("Main", "Session hours must be 0–23");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseSessionFilter && (InpSessionStartMin < 0 || InpSessionStartMin > 59
                           || InpSessionEndMin < 0   || InpSessionEndMin > 59))
   {
      LogError("Main", "Session minutes must be 0–59");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Risk limits
   if(InpMaxDDPercent < 0 || InpMaxDDPercent > 100)
   {
      LogError("Main", "Max DD% must be 0–100");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpDailyLossLimit < 0 || InpDailyLossLimit > 100)
   {
      LogError("Main", "Daily loss limit must be 0–100");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Daily trades (v2)
   if(InpMaxDailyTrades < 0)
   {
      LogError("Main", "Max daily trades must be >= 0 (0=unlimited)");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Loss cooldown (v2)
   if(InpLossCooldownSec < 0)
   {
      LogError("Main", "Loss cooldown seconds must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Trailing / break-even
   if(InpUseTrailingStop && InpTrailStartPts <= 0)
   {
      LogError("Main", "Trailing start must be > 0 when trailing is enabled");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseBreakEven && InpBEActivatePts <= 0)
   {
      LogError("Main", "Break-even activation must be > 0 when BE is enabled");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpSlippage < 0)
   {
      LogError("Main", "Slippage must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Symbol check
   if(!IsSymbolTradeable(_Symbol))
   {
      LogError("Main", "Symbol not tradeable: " + _Symbol);
      return INIT_FAILED;
   }

   //--- Initialise signal engine (create indicator handles incl. ATR)
   if(!SignalInit(_Symbol, _Period))
   {
      LogError("Main", "Signal engine init failed");
      return INIT_FAILED;
   }

   //--- Initialise risk manager
   RiskInit();

   //--- Start timer if requested
   if(InpTimerSeconds > 0)
   {
      if(!EventSetTimer(InpTimerSeconds))
         LogWarn("Main", "Failed to set timer");
      else
         LogInfo("Main", StringFormat("Timer set to %d seconds", InpTimerSeconds));
   }

   //--- Log initial account state
   LogAccountState();

   g_initOK = true;
   LogInfo("Main", "====== Init complete – EA v2 ready ======");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SignalDeinit();

   string reasonStr;
   switch(reason)
   {
      case REASON_PROGRAM:     reasonStr = "Program ended";        break;
      case REASON_REMOVE:      reasonStr = "EA removed from chart"; break;
      case REASON_RECOMPILE:   reasonStr = "Recompiled";           break;
      case REASON_CHARTCHANGE: reasonStr = "Chart symbol/period changed"; break;
      case REASON_CHARTCLOSE:  reasonStr = "Chart closed";         break;
      case REASON_PARAMETERS:  reasonStr = "Inputs changed";       break;
      case REASON_ACCOUNT:     reasonStr = "Account changed";      break;
      case REASON_TEMPLATE:    reasonStr = "Template applied";     break;
      case REASON_INITFAILED:  reasonStr = "Init failed";          break;
      case REASON_CLOSE:       reasonStr = "Terminal closed";      break;
      default:                 reasonStr = "Unknown (" + IntegerToString(reason) + ")"; break;
   }

   LogInfo("Main", "====== ProGridEA v2 OnDeinit – " + reasonStr + " ======");
}

//+------------------------------------------------------------------+
//| OnTick – the heartbeat of the EA                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_initOK) return;

   //--- Update equity peak for drawdown tracking
   RiskUpdateEquity();

   //--- Check for new trading day (daily loss limit + daily count reset)
   RiskNewDayCheck();

   //--- Manage existing positions (trailing / break-even)
   ManagePositions(_Symbol, InpMagicNumber);

   //--- One-trade-per-bar guard: skip signal generation if no new bar
   if(InpOneTradePerBar)
   {
      if(!IsNewBar(_Symbol, _Period, g_lastBarTime))
         return;  // Same bar – only manage positions, no new entries
   }

   //--- Pre-trade risk gate (all 12 gates)
   string reason = "";
   if(!PreTradeCheck(_Symbol, InpMagicNumber, reason))
   {
      LogDebug("Main", "PreTradeCheck blocked: " + reason);
      return;
   }

   //--- Generate signal
   ENUM_SIGNAL signal = GenerateSignal();
   if(signal == SIGNAL_NONE)
      return;

   //--- Buy/sell enable flag filter (v2)
   if(signal == SIGNAL_BUY && !InpEnableBuy)
   {
      LogDebug("Main", "BUY signal suppressed – Enable Buy is OFF");
      return;
   }
   if(signal == SIGNAL_SELL && !InpEnableSell)
   {
      LogDebug("Main", "SELL signal suppressed – Enable Sell is OFF");
      return;
   }

   //--- Duplicate direction check
   if(HasDuplicateDirection(_Symbol, InpMagicNumber, signal))
   {
      LogDebug("Main", "Duplicate direction – already have a " +
               ((signal == SIGNAL_BUY) ? "BUY" : "SELL") + " position");
      return;
   }

   //--- Execute trade
   LogInfo("Main", StringFormat("Signal=%s – attempting trade",
            (signal == SIGNAL_BUY) ? "BUY" : "SELL"));

   bool success = OpenMarketOrder(_Symbol, signal, InpMagicNumber, InpTradeComment);

   if(success)
      LogInfo("Main", "Trade opened successfully");
   else
      LogWarn("Main", "Trade attempt failed – see logs above");
}

//+------------------------------------------------------------------+
//| OnTimer – periodic tasks                                         |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_initOK) return;

   //--- Periodic account snapshot
   LogAccountState();

   //--- Could add housekeeping, heartbeat, external notifications here
   LogDebug("Main", "Timer tick");
}

//+------------------------------------------------------------------+
//| OnTradeTransaction – track server-side trade events              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      //--- Filter by magic: look up the deal in history
      if(!HistoryDealSelect(trans.deal))
         return;

      long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      if(dealMagic != InpMagicNumber)
         return;   // not our deal – ignore

      LogInfo("TradeTxn", StringFormat("DEAL_ADD deal=%I64u order=%I64u symbol=%s type=%d vol=%.2f price=%.5f",
               trans.deal, trans.order, trans.symbol,
               (int)trans.deal_type, trans.volume, trans.price));

      //--- v2: Detect losing deal close → record for cooldown
      long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT)
      {
         double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                           + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                           + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
         double dealVol    = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
         double dealPrice  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
         long   dealType   = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
         string dir        = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";

         //--- CSV log the close event
         LogCSV("CLOSE", trans.symbol, dir, dealVol, dealPrice, 0, 0, dealProfit,
                HistoryDealGetString(trans.deal, DEAL_COMMENT));

         if(dealProfit < 0)
         {
            LogInfo("TradeTxn", StringFormat("Losing close detected – profit=%.2f, activating cooldown", dealProfit));
            RiskRecordLoss();
         }
      }
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      LogDebug("TradeTxn", StringFormat("ORDER_ADD order=%I64u symbol=%s type=%d",
                trans.order, trans.symbol, (int)trans.order_type));
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      LogDebug("TradeTxn", StringFormat("ORDER_DELETE order=%I64u symbol=%s",
                trans.order, trans.symbol));
   }
   else if(trans.type == TRADE_TRANSACTION_HISTORY_ADD)
   {
      LogDebug("TradeTxn", StringFormat("HISTORY_ADD order=%I64u symbol=%s",
                trans.order, trans.symbol));
   }
   else if(trans.type == TRADE_TRANSACTION_REQUEST)
   {
      //--- Only log non-success results (DONE/PLACED are success)
      ENUM_EXEC_OUTCOME outcome = ClassifyRetcode(result.retcode);
      if(outcome != EXEC_OK)
      {
         LogWarn("TradeTxn", StringFormat("REQUEST failed retcode=%u (%s)",
                  result.retcode, RetcodeToString(result.retcode)));
      }
   }
}

//+------------------------------------------------------------------+
//| OnTrade – called when trade state changes (simpler alternative   |
//|           to OnTradeTransaction for basic bookkeeping)            |
//+------------------------------------------------------------------+
void OnTrade()
{
   LogDebug("Main", StringFormat("OnTrade – positions=%d orders=%d",
             PositionsTotal(), OrdersTotal()));
}

//+------------------------------------------------------------------+
//| OnTester – custom optimisation criterion (Strategy Tester)        |
//+------------------------------------------------------------------+
double OnTester()
{
   double profitFactor   = TesterStatistics(STAT_PROFIT_FACTOR);
   double recoveryFactor = TesterStatistics(STAT_RECOVERY_FACTOR);
   double trades         = TesterStatistics(STAT_TRADES);

   //--- Require minimum trades to avoid curve-fitting
   if(trades < 10)
      return 0.0;

   double criterion = profitFactor * recoveryFactor;
   LogInfo("Tester", StringFormat("OnTester: PF=%.2f RF=%.2f trades=%.0f criterion=%.4f",
            profitFactor, recoveryFactor, trades, criterion));
   return criterion;
}

//+------------------------------------------------------------------+
