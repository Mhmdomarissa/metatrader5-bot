//+------------------------------------------------------------------+
//|                                                  SymbolInfo.mqh  |
//|           StressTestEA – Symbol Property Cache & Helpers          |
//|                                                                  |
//|  Caches symbol properties once in OnInit.  Provides normalise,   |
//|  price, spread, filling-mode, and permission helpers.             |
//+------------------------------------------------------------------+
#ifndef SYMBOLINFO_MQH
#define SYMBOLINFO_MQH

//===================================================================
// Cached symbol properties (populated by CacheSymbolInfo)
//===================================================================
double   g_symMinLot      = 0.01;
double   g_symMaxLot      = 100.0;
double   g_symLotStep     = 0.01;
long     g_symFillFlags   = 0;
int      g_symDigits      = 5;
double   g_symPoint       = 0.00001;
int      g_symStopLevel   = 0;
int      g_symFreezeLevel = 0;
long     g_symTradeMode   = 0;
bool     g_isHedging      = false;

//===================================================================
// CacheSymbolInfo – call once in OnInit
//===================================================================
bool CacheSymbolInfo(string symbol)
{
   //--- Ensure symbol is in Market Watch
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT))
   {
      if(!SymbolSelect(symbol, true))
      {
         LogError("SymInfo", "Cannot select symbol: " + symbol);
         return false;
      }
   }

   g_symMinLot      = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   g_symMaxLot      = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   g_symLotStep     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   g_symFillFlags   = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   g_symDigits      = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   g_symPoint       = SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_symStopLevel   = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_symFreezeLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   g_symTradeMode   = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);

   //--- Account margin mode (hedging vs netting)
   ENUM_ACCOUNT_MARGIN_MODE mmode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_isHedging = (mmode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   //--- Validate essentials
   if(g_symMinLot <= 0 || g_symPoint <= 0 || g_symLotStep <= 0)
   {
      LogError("SymInfo", "Invalid symbol properties – cannot trade");
      return false;
   }

   LogInfo("SymInfo", StringFormat(
      "symbol=%s digits=%d point=%.5f minLot=%.4f maxLot=%.2f step=%.4f",
      symbol, g_symDigits, g_symPoint, g_symMinLot, g_symMaxLot, g_symLotStep));
   LogInfo("SymInfo", StringFormat(
      "stopLvl=%d freezeLvl=%d fillFlags=0x%X tradeMode=%d hedging=%s",
      g_symStopLevel, g_symFreezeLevel, (int)g_symFillFlags,
      (int)g_symTradeMode, g_isHedging ? "yes" : "no"));

   return true;
}

//===================================================================
// Volume normalisation
//===================================================================
double NormalizeLots(string symbol, double lots)
{
   if(g_symLotStep <= 0) return g_symMinLot;

   lots = MathFloor(lots / g_symLotStep) * g_symLotStep;
   if(lots < g_symMinLot) lots = g_symMinLot;
   if(lots > g_symMaxLot) lots = g_symMaxLot;

   int digits = (int)MathCeil(-MathLog10(g_symLotStep));
   return NormalizeDouble(lots, digits);
}

//===================================================================
// Price normalisation
//===================================================================
double NormalizePrice(string symbol, double price)
{
   return NormalizeDouble(price, g_symDigits);
}

//===================================================================
// Price helpers
//===================================================================
double GetAsk(string symbol)  { return SymbolInfoDouble(symbol, SYMBOL_ASK); }
double GetBid(string symbol)  { return SymbolInfoDouble(symbol, SYMBOL_BID); }

int GetSpreadPoints(string symbol)
{
   return (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
}

//===================================================================
// Filling mode detection
//===================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode(string symbol)
{
   long flags = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) != 0)  return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC) != 0)  return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//===================================================================
// Trading permission checks
//===================================================================

//--- Is algo trading allowed (EA + terminal)?
bool IsAlgoTradingAllowed()
{
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      LogDebug("SymInfo", "MQL_TRADE_ALLOWED = false");
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      LogDebug("SymInfo", "TERMINAL_TRADE_ALLOWED = false");
      return false;
   }
   return true;
}

//--- Is the symbol open for trading right now?
bool IsMarketOpen(string symbol)
{
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return false;

   ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;

   return true;
}

//--- Combined fast check for the trade cycle
bool IsTradingAllowedNow(string symbol)
{
   if(!IsAlgoTradingAllowed()) return false;
   if(!IsMarketOpen(symbol))   return false;
   return true;
}

#endif // SYMBOLINFO_MQH
