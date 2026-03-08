//+------------------------------------------------------------------+
//|                                            PositionManager.mqh   |
//|           StressTestEA – Position Counting & Close-Oldest         |
//|                                                                  |
//|  Counts open positions by magic/symbol/direction.  Provides      |
//|  close-oldest functionality for rotate-style stress testing.      |
//+------------------------------------------------------------------+
#ifndef POSITIONMANAGER_MQH
#define POSITIONMANAGER_MQH

//===================================================================
// Count buy positions for this EA on this symbol
//===================================================================
int CountBuyPositions(string symbol, long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic)  continue;
      if(PositionGetString(POSITION_SYMBOL)  != symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)   == POSITION_TYPE_BUY) count++;
   }
   return count;
}

//===================================================================
// Count sell positions for this EA on this symbol
//===================================================================
int CountSellPositions(string symbol, long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic)  continue;
      if(PositionGetString(POSITION_SYMBOL)  != symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)   == POSITION_TYPE_SELL) count++;
   }
   return count;
}

//===================================================================
// Count total positions for this EA on this symbol
//===================================================================
int CountTotalPositions(string symbol, long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      count++;
   }
   return count;
}

//===================================================================
// Get oldest position ticket for this EA on this symbol
//===================================================================
ulong GetOldestPositionTicket(string symbol, long magic)
{
   ulong    oldestTicket = 0;
   datetime oldestTime   = D'2099.01.01';

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime < oldestTime)
      {
         oldestTime   = openTime;
         oldestTicket = ticket;
      }
   }
   return oldestTicket;
}

//===================================================================
// Close a specific position by ticket
//===================================================================
bool ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
   {
      LogWarn("PosMgr", StringFormat("Cannot select ticket %I64u for close", ticket));
      return false;
   }

   string symbol  = PositionGetString(POSITION_SYMBOL);
   double volume  = PositionGetDouble(POSITION_VOLUME);
   long   posType = PositionGetInteger(POSITION_TYPE);

   ENUM_ORDER_TYPE closeType =
      (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double closePrice =
      (closeType == ORDER_TYPE_BUY) ? GetAsk(symbol) : GetBid(symbol);
   string dir = (closeType == ORDER_TYPE_BUY) ? "BUY" : "SELL";

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = symbol;
   req.volume       = volume;
   req.type         = closeType;
   req.price        = closePrice;
   req.deviation    = (uint)InpSlippage;
   req.magic        = InpMagicNumber;
   req.type_filling = DetectFillingMode(symbol);
   req.comment      = "close";

   OrderSend(req, res);

   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL)
   {
      LogInfo("PosMgr", StringFormat("Close OK ticket=%I64u vol=%.4f", ticket, volume));
      LogCSV("CLOSE", symbol, dir, volume, res.price, res.retcode,
             StringFormat("ticket=%I64u", ticket));
      return true;
   }

   LogWarn("PosMgr", StringFormat("Close FAILED ticket=%I64u retcode=%u (%s)",
            ticket, res.retcode, RetcodeToString(res.retcode)));
   LogCSV("CLOSE_FAIL", symbol, dir, volume, closePrice, res.retcode,
          StringFormat("ticket=%I64u %s", ticket, RetcodeToString(res.retcode)));
   return false;
}

//===================================================================
// Close the oldest position for this EA on this symbol
//===================================================================
bool CloseOldestPosition(string symbol, long magic)
{
   ulong ticket = GetOldestPositionTicket(symbol, magic);
   if(ticket == 0)
   {
      LogDebug("PosMgr", "No position found to close");
      return false;
   }
   return ClosePositionByTicket(ticket);
}

#endif // POSITIONMANAGER_MQH
