//+------------------------------------------------------------------+
//|                                                      Logger.mqh  |
//|           StressTestEA – Logging, CSV, Retcode Decoder            |
//|                                                                  |
//|  Tagged, leveled Print() wrappers.  CSV event logging for        |
//|  post-analysis.  Comprehensive retcode and transaction decoders.  |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

//===================================================================
// Log levels
//===================================================================
enum ENUM_LOG_LEVEL
{
   LOG_DEBUG = 0,
   LOG_INFO  = 1,
   LOG_WARN  = 2,
   LOG_ERROR = 3
};

//===================================================================
// Core logging
//===================================================================
void Log(ENUM_LOG_LEVEL level, string module, string message)
{
   if(level == LOG_DEBUG && !InpDebugMode) return;

   string prefix;
   switch(level)
   {
      case LOG_DEBUG: prefix = "[DEBUG]"; break;
      case LOG_INFO:  prefix = "[INFO] "; break;
      case LOG_WARN:  prefix = "[WARN] "; break;
      case LOG_ERROR: prefix = "[ERROR]"; break;
      default:        prefix = "[????] "; break;
   }
   PrintFormat("%s [%s] %s", prefix, module, message);
}

void LogDebug(string mod, string msg) { Log(LOG_DEBUG, mod, msg); }
void LogInfo (string mod, string msg) { Log(LOG_INFO,  mod, msg); }
void LogWarn (string mod, string msg) { Log(LOG_WARN,  mod, msg); }
void LogError(string mod, string msg) { Log(LOG_ERROR, mod, msg); }

//===================================================================
// CSV trade event logger
//===================================================================
//  Header: CSV,Time,Event,Symbol,Dir,Lots,Price,Retcode,RetcodeText,Comment
//
//  Events: ATTEMPT  – order about to be sent
//          ACCEPTED – server confirmed fill
//          REJECTED – server or OrderCheck rejected
//          RETRY    – transient error, retrying
//          CLOSE    – position close confirmed
//          CLOSE_FAIL – position close failed
//===================================================================
void LogCSV(string event, string symbol, string dir,
            double lots, double price, uint retcode, string comment)
{
   if(!InpCSVLogging) return;
   PrintFormat("CSV,%s,%s,%s,%s,%.4f,%.5f,%u,%s,%s",
               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
               event, symbol, dir, lots, price, retcode,
               RetcodeToString(retcode), comment);
}

//===================================================================
// CSV account snapshot
//===================================================================
//  Header: ACCT,Time,Balance,Equity,Margin,FreeMargin,MarginLevel,Positions
//===================================================================
void LogAccountCSV()
{
   if(!InpCSVLogging) return;
   PrintFormat("ACCT,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%d",
               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
               AccountInfoDouble(ACCOUNT_BALANCE),
               AccountInfoDouble(ACCOUNT_EQUITY),
               AccountInfoDouble(ACCOUNT_MARGIN),
               AccountInfoDouble(ACCOUNT_MARGIN_FREE),
               AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),
               PositionsTotal());
}

//===================================================================
// Retcode decoder
//===================================================================
string RetcodeToString(uint retcode)
{
   switch(retcode)
   {
      case 0:                                return "None";
      case TRADE_RETCODE_REQUOTE:            return "Requote";
      case TRADE_RETCODE_REJECT:             return "Rejected";
      case TRADE_RETCODE_CANCEL:             return "Cancelled";
      case TRADE_RETCODE_PLACED:             return "Placed";
      case TRADE_RETCODE_DONE:               return "Done";
      case TRADE_RETCODE_DONE_PARTIAL:       return "DonePartial";
      case TRADE_RETCODE_ERROR:              return "Error";
      case TRADE_RETCODE_TIMEOUT:            return "Timeout";
      case TRADE_RETCODE_INVALID:            return "Invalid";
      case TRADE_RETCODE_INVALID_VOLUME:     return "InvalidVolume";
      case TRADE_RETCODE_INVALID_PRICE:      return "InvalidPrice";
      case TRADE_RETCODE_INVALID_STOPS:      return "InvalidStops";
      case TRADE_RETCODE_TRADE_DISABLED:     return "TradeDisabled";
      case TRADE_RETCODE_MARKET_CLOSED:      return "MarketClosed";
      case TRADE_RETCODE_NO_MONEY:           return "NoMoney";
      case TRADE_RETCODE_PRICE_CHANGED:      return "PriceChanged";
      case TRADE_RETCODE_PRICE_OFF:          return "PriceOff";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "InvalidExpire";
      case TRADE_RETCODE_ORDER_CHANGED:      return "OrderChanged";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  return "TooManyReq";
      case TRADE_RETCODE_NO_CHANGES:         return "NoChanges";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "ServerDisablesAT";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "ClientDisablesAT";
      case TRADE_RETCODE_LOCKED:             return "Locked";
      case TRADE_RETCODE_FROZEN:             return "Frozen";
      case TRADE_RETCODE_CONNECTION:         return "NoConnection";
      case TRADE_RETCODE_ONLY_REAL:          return "OnlyReal";
      case TRADE_RETCODE_LIMIT_ORDERS:       return "LimitOrders";
      case TRADE_RETCODE_LIMIT_VOLUME:       return "LimitVolume";
      case TRADE_RETCODE_INVALID_ORDER:      return "InvalidOrder";
      case TRADE_RETCODE_POSITION_CLOSED:    return "PositionClosed";
      default:                               return "Unknown(" + IntegerToString(retcode) + ")";
   }
}

//===================================================================
// Transaction type decoder
//===================================================================
string TransactionTypeToString(ENUM_TRADE_TRANSACTION_TYPE type)
{
   switch(type)
   {
      case TRADE_TRANSACTION_ORDER_ADD:      return "ORDER_ADD";
      case TRADE_TRANSACTION_ORDER_UPDATE:   return "ORDER_UPDATE";
      case TRADE_TRANSACTION_ORDER_DELETE:   return "ORDER_DELETE";
      case TRADE_TRANSACTION_DEAL_ADD:       return "DEAL_ADD";
      case TRADE_TRANSACTION_DEAL_UPDATE:    return "DEAL_UPDATE";
      case TRADE_TRANSACTION_DEAL_DELETE:    return "DEAL_DELETE";
      case TRADE_TRANSACTION_HISTORY_ADD:    return "HISTORY_ADD";
      case TRADE_TRANSACTION_HISTORY_UPDATE: return "HISTORY_UPDATE";
      case TRADE_TRANSACTION_HISTORY_DELETE: return "HISTORY_DELETE";
      case TRADE_TRANSACTION_POSITION:       return "POSITION";
      case TRADE_TRANSACTION_REQUEST:        return "REQUEST";
      default:                               return "TXN_" + IntegerToString((int)type);
   }
}

//===================================================================
// Log MqlTradeRequest (verbose, for debug)
//===================================================================
void LogTradeRequest(const MqlTradeRequest &req)
{
   LogDebug("TradeReq", StringFormat("action=%d sym=%s type=%d vol=%.4f price=%.5f sl=%.5f tp=%.5f magic=%I64d fill=%d dev=%u",
            (int)req.action, req.symbol, (int)req.type,
            req.volume, req.price, req.sl, req.tp,
            req.magic, (int)req.type_filling, req.deviation));
}

//===================================================================
// Log MqlTradeResult (verbose, for debug)
//===================================================================
void LogTradeResult(const MqlTradeResult &result)
{
   LogDebug("TradeRes", StringFormat("retcode=%u deal=%I64u order=%I64u vol=%.4f price=%.5f comment=%s",
            result.retcode, result.deal, result.order,
            result.volume, result.price, result.comment));
}

#endif // LOGGER_MQH
