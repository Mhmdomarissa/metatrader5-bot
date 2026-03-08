//+------------------------------------------------------------------+
//|                                                      Config.mqh  |
//|           StressTestEA – Configuration & Input Parameters         |
//|                                                                  |
//|  All user-configurable inputs.  Grouped by category for the      |
//|  Strategy Tester and properties dialog.                          |
//|  DEMO / STRESS-TEST USE ONLY.                                    |
//+------------------------------------------------------------------+
#ifndef CONFIG_MQH
#define CONFIG_MQH

//===================================================================
// GROUP 1 – GENERAL
//===================================================================
input string   _G1_                = "══════ General ══════";          // ── Section ──
input long     InpMagicNumber      = 777777;      // Magic number
input string   InpTradeComment     = "StressEA";   // Order comment tag
input bool     InpDebugMode        = false;        // Verbose debug logging
input bool     InpCSVLogging       = true;         // CSV trade event logging

//===================================================================
// GROUP 2 – TRADE MODE
//===================================================================
input string   _G2_                = "══════ Trade Mode ══════";       // ── Section ──

enum ENUM_TRADE_MODE
{
   MODE_BUY_ONLY    = 0,   // Buy Only
   MODE_SELL_ONLY   = 1,   // Sell Only
   MODE_ALTERNATE   = 2,   // Alternate Buy / Sell
   MODE_BOTH        = 3    // Both Directions
};

input ENUM_TRADE_MODE InpTradeMode = MODE_BOTH;    // Order direction strategy

//===================================================================
// GROUP 3 – EXECUTION
//===================================================================
input string   _G3_                = "══════ Execution ══════";        // ── Section ──
input bool     InpTickExecution    = true;         // Execute on every tick
input bool     InpTimerExecution   = true;         // Execute on timer
input int      InpTimerMs          = 100;          // Timer interval (milliseconds)
input int      InpMaxReqPerCycle   = 5;            // Max order attempts per cycle
input int      InpPauseBetweenMs   = 50;           // Pause between attempts (ms)
input bool     InpBurstMode        = false;        // Burst mode (skip pause)

//===================================================================
// GROUP 4 – VOLUME
//===================================================================
input string   _G4_                = "══════ Volume ══════";           // ── Section ──
input double   InpLotSize          = 0.01;         // Fixed lot size

//===================================================================
// GROUP 5 – POSITION LIMITS
//===================================================================
input string   _G5_                = "══════ Position Limits ══════";  // ── Section ──
input int      InpMaxOpenTotal     = 50;           // Max total open positions
input int      InpMaxOpenBuy       = 25;           // Max buy positions
input int      InpMaxOpenSell      = 25;           // Max sell positions

//===================================================================
// GROUP 6 – POSITION MANAGEMENT
//===================================================================
input string   _G6_                = "══════ Position Mgmt ══════";    // ── Section ──
input bool     InpCloseOldest      = false;        // Close oldest when at limit
input bool     InpReEntryAfterClose = false;       // Re-enter immediately after close
input int      InpSlippage         = 50;           // Max slippage (points)

//===================================================================
// GROUP 7 – SAFEGUARDS
//===================================================================
input string   _G7_                = "══════ Safeguards ══════";       // ── Section ──
input int      InpMaxSpreadPts     = 100;          // Max spread (points, 0=off)
input double   InpMinFreeMargin    = 10.0;         // Min free margin to trade ($)
input double   InpEmergencyStopPct = 50.0;         // Emergency equity stop (% drop, 0=off)
input int      InpMaxRetries       = 3;            // Max retries per order

#endif // CONFIG_MQH
