//+------------------------------------------------------------------+
//|                                                SignalEngine.mqh   |
//|                        ProGridEA – Signal / Strategy Module       |
//|                                                                  |
//|  Isolated strategy logic.  Replace the body of GenerateSignal()  |
//|  with your own entry system – the rest of the EA stays the same. |
//+------------------------------------------------------------------+
#ifndef SIGNALENGINE_MQH
#define SIGNALENGINE_MQH

//===================================================================
// Signal enum returned to the main EA
//===================================================================
enum ENUM_SIGNAL
{
   SIGNAL_NONE  = 0,
   SIGNAL_BUY   = 1,
   SIGNAL_SELL   = 2
};

//===================================================================
// Indicator handles (initialised once in SignalInit)
//===================================================================
int g_handleFastMA = INVALID_HANDLE;
int g_handleSlowMA = INVALID_HANDLE;

//===================================================================
// Buffers for reading indicator values
//===================================================================
double g_fastMA[];   // Fast MA values
double g_slowMA[];   // Slow MA values

//===================================================================
// Init – create indicator handles
//===================================================================
bool SignalInit(string symbol, ENUM_TIMEFRAMES tf)
{
   g_handleFastMA = iMA(symbol, tf, InpFastMA, 0, InpMAMethod, InpMAPrice);
   g_handleSlowMA = iMA(symbol, tf, InpSlowMA, 0, InpMAMethod, InpMAPrice);

   if(g_handleFastMA == INVALID_HANDLE || g_handleSlowMA == INVALID_HANDLE)
   {
      LogError("Signal", StringFormat("Failed to create MA handles (fast=%d slow=%d)",
                g_handleFastMA, g_handleSlowMA));
      return false;
   }

   // Set buffers as timeseries (index 0 = most recent bar)
   ArraySetAsSeries(g_fastMA, true);
   ArraySetAsSeries(g_slowMA, true);

   LogInfo("Signal", StringFormat("MA indicators created – fast(%d) slow(%d) method=%d",
            InpFastMA, InpSlowMA, (int)InpMAMethod));
   return true;
}

//===================================================================
// Deinit – release indicator handles
//===================================================================
void SignalDeinit()
{
   if(g_handleFastMA != INVALID_HANDLE) { IndicatorRelease(g_handleFastMA); g_handleFastMA = INVALID_HANDLE; }
   if(g_handleSlowMA != INVALID_HANDLE) { IndicatorRelease(g_handleSlowMA); g_handleSlowMA = INVALID_HANDLE; }
   LogDebug("Signal", "Indicator handles released");
}

//===================================================================
// GenerateSignal – THE STRATEGY ENTRY POINT
//===================================================================
//  Default: simple MA crossover.
//  Bar[1] = previous completed bar, Bar[2] = bar before that.
//  BUY  when fast crosses above slow on bar 1.
//  SELL when fast crosses below slow on bar 1.
//
//  Replace this function with your own logic.
//===================================================================
ENUM_SIGNAL GenerateSignal()
{
   // We need at least 3 bars of data (index 0,1,2)
   if(CopyBuffer(g_handleFastMA, 0, 0, 3, g_fastMA) < 3) return SIGNAL_NONE;
   if(CopyBuffer(g_handleSlowMA, 0, 0, 3, g_slowMA) < 3) return SIGNAL_NONE;

   // Cross detection on the *completed* bar (index 1 vs 2)
   double fastPrev  = g_fastMA[2];   // two bars ago
   double fastCurr  = g_fastMA[1];   // last completed bar
   double slowPrev  = g_slowMA[2];
   double slowCurr  = g_slowMA[1];

   // BUY crossover: fast was below slow, now fast is above slow
   if(fastPrev <= slowPrev && fastCurr > slowCurr)
   {
      LogDebug("Signal", StringFormat("BUY cross: fast[2]=%.5f slow[2]=%.5f → fast[1]=%.5f slow[1]=%.5f",
                fastPrev, slowPrev, fastCurr, slowCurr));
      return SIGNAL_BUY;
   }

   // SELL crossover: fast was above slow, now fast is below slow
   if(fastPrev >= slowPrev && fastCurr < slowCurr)
   {
      LogDebug("Signal", StringFormat("SELL cross: fast[2]=%.5f slow[2]=%.5f → fast[1]=%.5f slow[1]=%.5f",
                fastPrev, slowPrev, fastCurr, slowCurr));
      return SIGNAL_SELL;
   }

   return SIGNAL_NONE;
}

#endif // SIGNALENGINE_MQH
