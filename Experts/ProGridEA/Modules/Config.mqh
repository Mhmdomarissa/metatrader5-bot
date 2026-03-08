//+------------------------------------------------------------------+
//|                                                      Config.mqh  |
//|                        ProGridEA v2 – Configuration & Inputs      |
//|                                                                  |
//|  All user-configurable inputs live here. Grouped by category     |
//|  so MetaEditor's Strategy Tester shows them in a readable way.   |
//+------------------------------------------------------------------+
#ifndef CONFIG_MQH
#define CONFIG_MQH

//===================================================================
// GROUP 1 – GENERAL
//===================================================================
input string   _G1_              = "══════ General ══════";           // ── Section ──
input long     InpMagicNumber    = 123456;     // Magic number (unique per EA instance)
input string   InpTradeComment   = "ProGrid";  // Order comment tag
input bool     InpDebugMode      = false;      // Enable verbose debug logging
input int      InpSlippage       = 20;         // Max slippage in points
input bool     InpEnableBuy      = true;       // Allow BUY trades
input bool     InpEnableSell     = true;       // Allow SELL trades
input bool     InpCSVLogging     = false;      // CSV-style trade logging in Journal

//===================================================================
// GROUP 2 – STRATEGY / SIGNAL
//===================================================================
input string   _G2_              = "══════ Strategy ══════";          // ── Section ──
input int      InpFastMA         = 10;         // Fast MA period
input int      InpSlowMA         = 50;         // Slow MA period
input ENUM_MA_METHOD      InpMAMethod   = MODE_SMA;   // MA method
input ENUM_APPLIED_PRICE  InpMAPrice    = PRICE_CLOSE; // Applied price
input bool     InpOneTradePerBar = true;       // Allow only one trade per bar

//===================================================================
// GROUP 3 – RISK MANAGEMENT
//===================================================================
input string   _G3_              = "══════ Risk ══════";              // ── Section ──

enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED  = 0,   // Fixed lot size
   LOT_MODE_RISK   = 1    // Risk % per trade
};

enum ENUM_SL_TP_MODE
{
   SLTP_FIXED = 0,   // Fixed points
   SLTP_ATR   = 1    // ATR-based
};

input ENUM_LOT_MODE   InpLotMode     = LOT_MODE_FIXED;  // Lot sizing mode
input double   InpFixedLots          = 0.01;    // Fixed lot size
input double   InpRiskPercent        = 1.0;     // Risk % of balance per trade

input ENUM_SL_TP_MODE InpSLTPMode    = SLTP_FIXED;  // SL/TP calculation mode
input double   InpStopLoss           = 200.0;   // Stop-loss in points (fixed mode, 0=none)
input double   InpTakeProfit         = 400.0;   // Take-profit in points (fixed mode, 0=none)
input int      InpATRPeriod          = 14;       // ATR period (ATR mode)
input double   InpATRMultSL          = 1.5;     // ATR multiplier for SL (ATR mode)
input double   InpATRMultTP          = 2.0;     // ATR multiplier for TP (ATR mode)

//===================================================================
// GROUP 4 – SAFEGUARDS
//===================================================================
input string   _G4_              = "══════ Safeguards ══════";        // ── Section ──
input int      InpMaxSpreadPts   = 30;         // Max allowed spread (points, 0=off)
input int      InpMaxOpenPos     = 3;          // Max simultaneous open positions
input int      InpCooldownSec    = 10;         // Cooldown between trades (seconds)
input int      InpLossCooldownSec = 30;        // Extra cooldown after a loss (seconds, 0=off)
input double   InpMaxDDPercent   = 10.0;       // Max equity drawdown % (0=off)
input double   InpMinFreeMargin  = 100.0;      // Min free margin to trade
input double   InpMinMarginLevel = 150.0;      // Min margin level % (0=off)
input double   InpDailyLossLimit = 5.0;        // Daily loss limit % of starting balance (0=off)
input int      InpMaxDailyTrades = 0;          // Max trades per day (0=unlimited)
input int      InpMaxRetries     = 3;          // Max retries on requote / price change

//===================================================================
// GROUP 5 – SESSION FILTER
//===================================================================
input string   _G5_              = "══════ Session ══════";           // ── Section ──
input bool     InpUseSessionFilter  = false;    // Enable session filter
input int      InpSessionStartHour  = 8;        // Session start hour (server time)
input int      InpSessionStartMin   = 0;        // Session start minute
input int      InpSessionEndHour    = 18;       // Session end hour   (server time)
input int      InpSessionEndMin     = 0;        // Session end minute

//===================================================================
// GROUP 6 – TRAILING / BREAK-EVEN
//===================================================================
input string   _G6_              = "══════ Trail / BE ══════";        // ── Section ──
input bool     InpUseTrailingStop  = false;     // Enable trailing stop
input double   InpTrailStartPts    = 200.0;    // Trailing start (points in profit)
input double   InpTrailStepPts     = 50.0;     // Trailing step (points)
input bool     InpUseBreakEven     = false;     // Enable break-even
input double   InpBEActivatePts    = 150.0;    // Break-even activation (points)
input double   InpBEOffsetPts      = 10.0;     // Break-even offset (lock-in points)

//===================================================================
// GROUP 7 – TIMER
//===================================================================
input string   _G7_              = "══════ Timer ══════";             // ── Section ──
input int      InpTimerSeconds   = 60;          // OnTimer interval (seconds, 0=off)

#endif // CONFIG_MQH
