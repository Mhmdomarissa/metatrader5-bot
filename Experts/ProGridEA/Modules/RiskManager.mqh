//+------------------------------------------------------------------+
//|                                                 RiskManager.mqh   |
//|                        ProGridEA – Risk & Safeguard Module        |
//|                                                                  |
//|  Every pre-trade and account-level safety check lives here.      |
//|  Returns clear pass/fail with a reason string.                   |
//+------------------------------------------------------------------+
#ifndef RISKMANAGER_MQH
#define RISKMANAGER_MQH

//===================================================================
// Internal state
//===================================================================
double   g_dayStartBalance  = 0;      // Balance at start of trading day
datetime g_dayStartDate     = 0;      // Date of last recorded day-start
datetime g_lastTradeTime    = 0;      // Time of most recent trade executed
double   g_peakEquity       = 0;      // Highest equity since EA start (for DD guard)

//===================================================================
// RiskInit – call from OnInit
//===================================================================
void RiskInit()
{
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   g_dayStartDate = StructToTime(dt);

   LogInfo("Risk", StringFormat("Init – balance=%.2f equity=%.2f peakEquity=%.2f",
            g_dayStartBalance, g_peakEquity, g_peakEquity));
}

//===================================================================
// RiskNewDay – call periodically to detect day rollover
//===================================================================
void RiskNewDayCheck()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_dayStartDate)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayStartDate    = today;
      LogInfo("Risk", StringFormat("New day detected – resetting daily PnL baseline to %.2f", g_dayStartBalance));
   }
}

//===================================================================
// Update peak equity (call on each tick for DD tracking)
//===================================================================
void RiskUpdateEquity()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity)
      g_peakEquity = eq;
}

//===================================================================
// PreTradeCheck – Master gate.  Call BEFORE opening a new trade.
// Returns true if ALL checks pass; otherwise sets reason string.
//===================================================================
bool PreTradeCheck(string symbol, long magic, string &reason)
{
   //--- 1) Trading permissions
   if(!IsTradingAllowed())
   {
      reason = "Trading not allowed (terminal/account/EA)";
      return false;
   }

   //--- 2) Symbol tradeable
   if(!IsSymbolTradeable(symbol))
   {
      reason = "Symbol not tradeable: " + symbol;
      return false;
   }

   //--- 3) Session filter
   if(InpUseSessionFilter && !IsWithinSession(InpSessionStartHour, InpSessionEndHour))
   {
      reason = "Outside trading session";
      return false;
   }

   //--- 4) Max spread
   if(InpMaxSpreadPts > 0)
   {
      int spread = GetSpreadPoints(symbol);
      if(spread > InpMaxSpreadPts)
      {
         reason = StringFormat("Spread too wide (%d > %d pts)", spread, InpMaxSpreadPts);
         return false;
      }
   }

   //--- 5) Max open positions
   if(InpMaxOpenPos > 0)
   {
      int openCount = CountMyPositions(symbol, magic);
      if(openCount >= InpMaxOpenPos)
      {
         reason = StringFormat("Max open positions reached (%d)", openCount);
         return false;
      }
   }

   //--- 6) Cooldown
   if(InpCooldownSec > 0 && g_lastTradeTime > 0)
   {
      long elapsed = (long)(TimeCurrent() - g_lastTradeTime);
      if(elapsed < InpCooldownSec)
      {
         reason = StringFormat("Cooldown active (%d / %d sec)", (int)elapsed, InpCooldownSec);
         return false;
      }
   }

   //--- 7) Free margin guard
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin < InpMinFreeMargin)
   {
      reason = StringFormat("Free margin too low (%.2f < %.2f)", freeMargin, InpMinFreeMargin);
      return false;
   }

   //--- 8) Margin level guard
   if(InpMinMarginLevel > 0)
   {
      double marginLvl = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      // Margin level is 0 when no positions are open – that's fine
      if(marginLvl > 0 && marginLvl < InpMinMarginLevel)
      {
         reason = StringFormat("Margin level too low (%.2f%% < %.2f%%)", marginLvl, InpMinMarginLevel);
         return false;
      }
   }

   //--- 9) Equity drawdown guard
   if(InpMaxDDPercent > 0 && g_peakEquity > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct  = (g_peakEquity - equity) / g_peakEquity * 100.0;
      if(ddPct >= InpMaxDDPercent)
      {
         reason = StringFormat("Equity DD limit hit (%.2f%% >= %.2f%%)", ddPct, InpMaxDDPercent);
         return false;
      }
   }

   //--- 10) Daily loss limit (equity-based to include unrealised losses)
   if(InpDailyLossLimit > 0 && g_dayStartBalance > 0)
   {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double dayLoss = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
      if(dayLoss >= InpDailyLossLimit)
      {
         reason = StringFormat("Daily loss limit hit (%.2f%% >= %.2f%%) [equity-based]", dayLoss, InpDailyLossLimit);
         return false;
      }
   }

   reason = "";
   return true;
}

//===================================================================
// Calculate lot size
//===================================================================
double CalculateLotSize(string symbol, double slPoints)
{
   if(InpLotMode == LOT_MODE_FIXED)
      return NormaliseLots(symbol, InpFixedLots);

   // LOT_MODE_RISK: risk a percentage of balance on the stop-loss distance
   if(slPoints <= 0)
   {
      LogWarn("Risk", "Risk-per-trade mode requires a stop loss – falling back to fixed lots");
      return NormaliseLots(symbol, InpFixedLots);
   }

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = GetTickValue(symbol);
   double tickSize  = GetTickSize(symbol);
   double pointVal  = GetPoint(symbol);

   if(tickValue <= 0 || tickSize <= 0 || pointVal <= 0)
   {
      LogWarn("Risk", "Cannot compute tick value – falling back to fixed lots");
      return NormaliseLots(symbol, InpFixedLots);
   }

   // Value of 1 point move for 1 lot
   double pointValuePerLot = tickValue * pointVal / tickSize;

   double lots = riskMoney / (slPoints * pointValuePerLot);
   lots = NormaliseLots(symbol, lots);

   LogDebug("Risk", StringFormat("RiskCalc: bal=%.2f risk$=%.2f slPts=%.0f pvpl=%.5f → lots=%.2f",
             balance, riskMoney, slPoints, pointValuePerLot, lots));
   return lots;
}

//===================================================================
// Record that a trade was executed (for cooldown)
//===================================================================
void RiskRecordTrade()
{
   g_lastTradeTime = TimeCurrent();
}

#endif // RISKMANAGER_MQH
