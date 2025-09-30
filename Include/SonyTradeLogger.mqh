//+------------------------------------------------------------------+
//| SonyTradeLogger.mqh                                                  |
//| Provides trade logging to WebRequest endpoint as JSON             |
//+------------------------------------------------------------------+
class SonyTradeLogger
  {
private:
   string url;
   string headers;
   int timeout;

public:
   SonyTradeLogger(string _url, int _timeout = 10000)
     {
      url     = _url;
      headers = "Content-Type: application/json\r\n";
      timeout = _timeout;
     }

   // Log a trade (call on open/close)
   void LogTrade(
         string trade_type,
         double lots,
         string symbol,
         double open_price,
         datetime open_time,
         double close_price,
         datetime close_time,
         double profit)
     {
      long account_id = AccountInfoInteger(ACCOUNT_LOGIN);

      string json = "{";
      json += "\"user_id\":" + IntegerToString(account_id) + ",";
      json += "\"type\":\"" + trade_type + "\",";
      json += "\"symbol\":\"" + symbol + "\",";
      json += "\"lots\":" + DoubleToString(lots, 2) + ",";
      json += "\"open_price\":" + DoubleToString(open_price, 5) + ",";
      json += "\"open_time\":\"" + TimeToString(open_time, TIME_DATE|TIME_SECONDS) + "\",";
      json += "\"close_price\":" + DoubleToString(close_price, 5) + ",";
      json += "\"close_time\":\"" + TimeToString(close_time, TIME_DATE|TIME_SECONDS) + "\",";
      json += "\"profit\":" + DoubleToString(profit, 2);
      json += "}";
      
      Print("TradeLogger JSON: ", json);

      //char result[];
      //int res = WebRequest("POST", url, headers, NULL, json, result, timeout);

      //if(res == -1)
        // Print("TradeLogger WebRequest error: ", GetLastError());
      //else
        // Print("TradeLogger: record sent. Result: ", CharArrayToString(result));
     }
  };