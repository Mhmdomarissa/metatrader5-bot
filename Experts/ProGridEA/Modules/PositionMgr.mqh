//+------------------------------------------------------------------+
//|                                                PositionMgr.mqh    |
//|                        ProGridEA – Position Management Module     |
//|                                                                  |
//|  Handles trailing stop, break-even, and position tracking for    |
//|  all positions owned by this EA (matched by magic number).       |
//+------------------------------------------------------------------+
#ifndef POSITIONMGR_MQH
#define POSITIONMGR_MQH

//===================================================================
// ModifySLTP – modify SL/TP on an existing position
//===================================================================
bool ModifyPositionSLTP(ulong ticket, double newSL, double newTP)
{
   //--- Ensure position is selected so we can read its symbol
   if(!PositionSelectByTicket(ticket))
   {
      LogWarn("PosMgr", StringFormat("ModifySLTP – cannot select ticket %I64u", ticket));
      return false;
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = PositionGetString(POSITION_SYMBOL);
   req.sl       = NormalisePrice(req.symbol, newSL);
   req.tp       = NormalisePrice(req.symbol, newTP);

   LogDebug("PosMgr", StringFormat("ModifySLTP ticket=%I64u sl=%.5f tp=%.5f", ticket, req.sl, req.tp));

   if(!OrderSend(req, res))
   {
      //--- NO_CHANGES is harmless – SL/TP already at the requested value
      if(res.retcode == TRADE_RETCODE_NO_CHANGES)
      {
         LogDebug("PosMgr", StringFormat("ModifySLTP no change needed ticket=%I64u", ticket));
         return true;
      }
      LogWarn("PosMgr", StringFormat("ModifySLTP FAILED ticket=%I64u retcode=%u (%s)",
               ticket, res.retcode, RetcodeToString(res.retcode)));
      return false;
   }

   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL
      || res.retcode == TRADE_RETCODE_NO_CHANGES)
   {
      LogDebug("PosMgr", StringFormat("ModifySLTP OK ticket=%I64u", ticket));
      return true;
   }

   LogWarn("PosMgr", StringFormat("ModifySLTP unexpected retcode=%u ticket=%I64u", res.retcode, ticket));
   return false;
}

//===================================================================
// TrailingStop – move SL to lock in profits
//===================================================================
//  Activates only when the position is in profit by at least
//  InpTrailStartPts.  Then trails the SL by InpTrailStepPts below
//  the current price (for buys) or above (for sells).
//===================================================================
void ApplyTrailingStop(ulong ticket)
{
   if(!InpUseTrailingStop) return;
   if(!PositionSelectByTicket(ticket)) return;   // re-select to get fresh data

   string symbol = PositionGetString(POSITION_SYMBOL);
   double point  = GetPoint(symbol);
   if(point <= 0) return;   // symbol data not ready

   long   posType = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);

   if(posType == POSITION_TYPE_BUY)
   {
      double bid = GetBid(symbol);
      double profitPts = (bid - openPrice) / point;

      if(profitPts < InpTrailStartPts) return;   // Not enough profit yet

      double newSL = NormalisePrice(symbol, bid - InpTrailStepPts * point);

      // Only move SL up, never down
      if(newSL > curSL || curSL == 0)
      {
         LogDebug("PosMgr", StringFormat("TrailBUY ticket=%I64u bid=%.5f newSL=%.5f oldSL=%.5f",
                   ticket, bid, newSL, curSL));
         ModifyPositionSLTP(ticket, newSL, curTP);
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double ask = GetAsk(symbol);
      double profitPts = (openPrice - ask) / point;

      if(profitPts < InpTrailStartPts) return;

      double newSL = NormalisePrice(symbol, ask + InpTrailStepPts * point);

      // Only move SL down (for sells), never up
      if(newSL < curSL || curSL == 0)
      {
         LogDebug("PosMgr", StringFormat("TrailSELL ticket=%I64u ask=%.5f newSL=%.5f oldSL=%.5f",
                   ticket, ask, newSL, curSL));
         ModifyPositionSLTP(ticket, newSL, curTP);
      }
   }
}

//===================================================================
// BreakEven – move SL to entry + offset once profit threshold met
//===================================================================
void ApplyBreakEven(ulong ticket)
{
   if(!InpUseBreakEven) return;
   if(!PositionSelectByTicket(ticket)) return;   // re-select to get fresh data

   string symbol = PositionGetString(POSITION_SYMBOL);
   double point  = GetPoint(symbol);
   if(point <= 0) return;   // symbol data not ready

   long   posType = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);

   if(posType == POSITION_TYPE_BUY)
   {
      double bid = GetBid(symbol);
      double profitPts = (bid - openPrice) / point;

      if(profitPts < InpBEActivatePts) return;

      double beSL = NormalisePrice(symbol, openPrice + InpBEOffsetPts * point);

      // Only apply if SL is still below break-even
      if(curSL < beSL || curSL == 0)
      {
         LogDebug("PosMgr", StringFormat("BreakEvenBUY ticket=%I64u beSL=%.5f oldSL=%.5f", ticket, beSL, curSL));
         ModifyPositionSLTP(ticket, beSL, curTP);
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double ask = GetAsk(symbol);
      double profitPts = (openPrice - ask) / point;

      if(profitPts < InpBEActivatePts) return;

      double beSL = NormalisePrice(symbol, openPrice - InpBEOffsetPts * point);

      // Only apply if SL is still above break-even
      if(curSL > beSL || curSL == 0)
      {
         LogDebug("PosMgr", StringFormat("BreakEvenSELL ticket=%I64u beSL=%.5f oldSL=%.5f", ticket, beSL, curSL));
         ModifyPositionSLTP(ticket, beSL, curTP);
      }
   }
}

//===================================================================
// ManagePositions – iterate all EA positions and apply rules
//===================================================================
//  Called on every tick (or on timer).
//===================================================================
void ManagePositions(string symbol, long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // Filter: only our EA
      if(PositionGetInteger(POSITION_MAGIC)  != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      //--- Apply break-even first (it's a one-time move)
      ApplyBreakEven(ticket);

      //--- Then trailing (ongoing)
      ApplyTrailingStop(ticket);
   }
}

//===================================================================
// HasDuplicateDirection – check if we already have a position in
// the same direction (prevents re-entering the same side)
//===================================================================
bool HasDuplicateDirection(string symbol, long magic, ENUM_SIGNAL signal)
{
   if(signal == SIGNAL_NONE) return false;

   long matchType = (signal == SIGNAL_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic)  continue;
      if(PositionGetString(POSITION_SYMBOL)  != symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)   == matchType)
         return true;
   }
   return false;
}

#endif // POSITIONMGR_MQH
