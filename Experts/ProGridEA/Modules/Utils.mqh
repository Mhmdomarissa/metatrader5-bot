//+------------------------------------------------------------------+
//|                                                       Utils.mqh  |
//|                        ProGridEA – Utilities & Helpers            |
//|                                                                  |
//|  Pure helper functions with no side effects.  Anything that       |
//|  doesn't belong to a specific module lives here.                 |
//+------------------------------------------------------------------+
#ifndef UTILS_MQH
#define UTILS_MQH

//===================================================================
// SYMBOL HELPERS
//===================================================================

//--- Normalise a volume to the symbol's lot step / min / max
double NormaliseLots(string symbol, double lots)
{
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   // Round to nearest step
   lots = MathFloor(lots / lotStep) * lotStep;

   // Clamp
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   // Final normalization to avoid floating-point drift
   int digits = (int)MathCeil(-MathLog10(lotStep));
   lots = NormalizeDouble(lots, digits);
   return lots;
}

//--- Get current spread in points
int GetSpreadPoints(string symbol)
{
   return (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
}

//--- Get point value for a symbol
double GetPoint(string symbol)
{
   return SymbolInfoDouble(symbol, SYMBOL_POINT);
}

//--- Get digits for a symbol
int GetDigits(string symbol)
{
   return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
}

//===================================================================
// PRICE HELPERS
//===================================================================

//--- Best ask
double GetAsk(string symbol)
{
   return SymbolInfoDouble(symbol, SYMBOL_ASK);
}

//--- Best bid
double GetBid(string symbol)
{
   return SymbolInfoDouble(symbol, SYMBOL_BID);
}

//--- Normalise price to symbol digits
double NormalisePrice(string symbol, double price)
{
   return NormalizeDouble(price, GetDigits(symbol));
}

//===================================================================
// TIME / BAR HELPERS
//===================================================================

//--- Return open time of the current (most recent) bar
datetime CurrentBarTime(string symbol, ENUM_TIMEFRAMES tf)
{
   datetime barTime = 0;
   // iTime is the safe MQL5 way
   barTime = iTime(symbol, tf, 0);
   return barTime;
}

//--- Has a new bar formed since lastBarTime?
bool IsNewBar(string symbol, ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime cur = CurrentBarTime(symbol, tf);
   if(cur == 0) return false;          // data not ready
   if(cur != lastBarTime)
   {
      lastBarTime = cur;
      return true;
   }
   return false;
}

//===================================================================
// ACCOUNT / PERMISSION CHECKS
//===================================================================

//--- Is algorithmic trading allowed in the terminal + account?
bool IsTradingAllowed()
{
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      LogWarn("Utils", "MQL trade not allowed (check AutoTrading button / EA properties)");
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      LogWarn("Utils", "Terminal trade not allowed");
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      LogWarn("Utils", "Account trade not allowed");
      return false;
   }
   // TRADE_MODE_DEMO=0, TRADE_MODE_CONTEST=1, TRADE_MODE_REAL=2
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   // We allow all modes; just log
   LogDebug("Utils", StringFormat("Account trade mode=%d", (int)mode));
   return true;
}

//--- Is the symbol tradeable right now?
bool IsSymbolTradeable(string symbol)
{
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT))
   {
      // Try to add it to Market Watch
      if(!SymbolSelect(symbol, true))
      {
         LogError("Utils", "Cannot select symbol " + symbol);
         return false;
      }
   }

   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      LogWarn("Utils", "Symbol " + symbol + " trading is disabled");
      return false;
   }
   return true;
}

//===================================================================
// SESSION FILTER
//===================================================================

//--- Is the current server time within the configured session window?
bool IsWithinSession(int startHour, int endHour)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;

   if(startHour <= endHour)
      return (hour >= startHour && hour < endHour);
   else // Overnight window e.g. 22–06
      return (hour >= startHour || hour < endHour);
}

//===================================================================
// POSITION COUNTING
//===================================================================

//--- Count open positions for this EA (by magic number + symbol)
int CountMyPositions(string symbol, long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == symbol)
         count++;
   }
   return count;
}

//--- Count ALL open positions for this EA across all symbols
int CountAllMyPositions(long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         count++;
   }
   return count;
}

//===================================================================
// MISC
//===================================================================

//--- Tick value in account currency for 1 lot of the symbol
double GetTickValue(string symbol)
{
   return SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
}

//--- Tick size
double GetTickSize(string symbol)
{
   return SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
}

#endif // UTILS_MQH
