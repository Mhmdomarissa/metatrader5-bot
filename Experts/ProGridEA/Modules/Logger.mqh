//+------------------------------------------------------------------+
//|                                                      Logger.mqh  |
//|                        ProGridEA – Structured Logging Module      |
//|                                                                  |
//|  Provides tagged, leveled Print() wrappers so every log line     |
//|  is easy to filter in the Experts/Journal tab.                   |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

//--- Forward-reference to InpDebugMode from Config.mqh (already included by main EA)

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
// Core logging function
//===================================================================
void Log(ENUM_LOG_LEVEL level, string module, string message)
{
   // Skip DEBUG messages unless debug mode is on
   if(level == LOG_DEBUG && !InpDebugMode)
      return;

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

//===================================================================
// Convenience wrappers
//===================================================================
void LogDebug(string module, string msg) { Log(LOG_DEBUG, module, msg); }
void LogInfo (string module, string msg) { Log(LOG_INFO,  module, msg); }
void LogWarn (string module, string msg) { Log(LOG_WARN,  module, msg); }
void LogError(string module, string msg) { Log(LOG_ERROR, module, msg); }

//===================================================================
// Specialised loggers
//===================================================================

//--- Log a trade request before sending
void LogTradeRequest(const MqlTradeRequest &req)
{
   PrintFormat("[INFO]  [TradeReq] action=%d symbol=%s type=%d vol=%.2f price=%.5f sl=%.5f tp=%.5f magic=%I64d filling=%d deviation=%u comment=%s",
               (int)req.action, req.symbol, (int)req.type,
               req.volume, req.price, req.sl, req.tp,
               req.magic, (int)req.type_filling, req.deviation, req.comment);
}

//--- Log the result after OrderSend / OrderCheck
void LogTradeResult(const MqlTradeResult &result)
{
   PrintFormat("[INFO]  [TradeRes] retcode=%u deal=%I64u order=%I64u vol=%.2f price=%.5f comment=%s",
               result.retcode, result.deal, result.order,
               result.volume, result.price, result.comment);
}

//--- Log MqlTradeCheckResult from OrderCheck
void LogCheckResult(const MqlTradeCheckResult &check)
{
   PrintFormat("[INFO]  [OrdCheck] retcode=%u balance=%.2f equity=%.2f margin=%.2f free_margin=%.2f comment=%s",
               check.retcode, check.balance, check.equity,
               check.margin, check.margin_free, check.comment);
}

//--- Log account snapshot (useful on init and periodically)
void LogAccountState()
{
   PrintFormat("[INFO]  [Account] balance=%.2f equity=%.2f margin=%.2f free=%.2f level=%.2f%% positions=%d",
               AccountInfoDouble(ACCOUNT_BALANCE),
               AccountInfoDouble(ACCOUNT_EQUITY),
               AccountInfoDouble(ACCOUNT_MARGIN),
               AccountInfoDouble(ACCOUNT_MARGIN_FREE),
               AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),
               PositionsTotal());
}

//--- Decode common retcodes to human-readable strings
string RetcodeToString(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:           return "Requote";
      case TRADE_RETCODE_REJECT:            return "Rejected";
      case TRADE_RETCODE_CANCEL:            return "Cancelled";
      case TRADE_RETCODE_PLACED:            return "Placed";
      case TRADE_RETCODE_DONE:              return "Done";
      case TRADE_RETCODE_DONE_PARTIAL:      return "Done (partial)";
      case TRADE_RETCODE_ERROR:             return "General error";
      case TRADE_RETCODE_TIMEOUT:           return "Timeout";
      case TRADE_RETCODE_INVALID:           return "Invalid request";
      case TRADE_RETCODE_INVALID_VOLUME:    return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE:     return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS:     return "Invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED:    return "Trade disabled";
      case TRADE_RETCODE_MARKET_CLOSED:     return "Market closed";
      case TRADE_RETCODE_NO_MONEY:          return "Not enough money";
      case TRADE_RETCODE_PRICE_CHANGED:     return "Price changed";
      case TRADE_RETCODE_PRICE_OFF:         return "Price off";
      case TRADE_RETCODE_INVALID_EXPIRATION:return "Invalid expiration";
      case TRADE_RETCODE_ORDER_CHANGED:     return "Order changed";
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return "Too many requests";
      case TRADE_RETCODE_NO_CHANGES:        return "No changes";
      case TRADE_RETCODE_SERVER_DISABLES_AT:return "Autotrading disabled server";
      case TRADE_RETCODE_CLIENT_DISABLES_AT:return "Autotrading disabled client";
      case TRADE_RETCODE_LOCKED:            return "Locked";
      case TRADE_RETCODE_FROZEN:            return "Frozen";
      case TRADE_RETCODE_CONNECTION:        return "No connection";
      case TRADE_RETCODE_ONLY_REAL:         return "Only real accounts";
      case TRADE_RETCODE_LIMIT_ORDERS:      return "Limit orders exceeded";
      case TRADE_RETCODE_LIMIT_VOLUME:      return "Volume limit exceeded";
      case TRADE_RETCODE_INVALID_ORDER:     return "Invalid order";
      case TRADE_RETCODE_POSITION_CLOSED:   return "Position closed";
      default:                              return "Unknown (" + IntegerToString(retcode) + ")";
   }
}

#endif // LOGGER_MQH
