//+------------------------------------------------------------------+
//| TestLayersEA.mq5  (SELL-only minimal version)                    |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

// Logger include (always enabled)
#include <SonyTradeLogger.mqh>
//--- Inputs Https server api
input string TradeLogAPI_URL = "https://your-server.com/api/save_trade";
input int WebRequestTimeout = 10000;

//--- Trading Inputs
input double BaseLots = 0.01;
input double StepSize = 1.0;
input int StepsPerLayer = 5;
input double ProfitTargetPercent = 20.0;
input int Slippage = 10;
input int MaxOrders = 15;
input double MaxTotalLots = 1.0;
input bool AutoRestart = true;
input bool AutoStartOnInit = true;
input ulong MagicNumber = 2025091901;

//--- Global Variables
double last_entry_price = 0.0;
bool sequence_active = false;

// Time-based Lock for duplicate prevention
datetime last_trade_time = 0;
const int TRADE_COOLDOWN_SECONDS = 5; // Wait 5 seconds after a trade attempt

SonyTradeLogger logger(TradeLogAPI_URL, WebRequestTimeout);

struct Stats
{
  int count;
  double totalVolume;
  double totalInvested;
  double floatingProfit;
  double lastPrice;
  double lastVol;
};

//+------------------------------------------------------------------+
//| Normalizes the volume to the symbol's step size.                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
{
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

  if (step <= 0.0)
  {
    step = BaseLots; // Default to baseLots size if step is not available
  }

  Print("-original-Volume- ", DoubleToString(vol, 2), "-Step-", DoubleToString(step, 2), " -min-v- ", DoubleToString(vmin, 2), " -max-v-", DoubleToString(vmax, 2));

  vol = MathMax(vmin, MathMin(vol, vmax));
  vol = MathRound(vol / step) * step;
  return NormalizeDouble(vol, (int)MathRound(-log10(step)));
}

//+------------------------------------------------------------------+
//| Collects statistics on open SELL positions with this magic       |
//+------------------------------------------------------------------+
void CollectStats(Stats &s)
{
  ZeroMemory(s);
  datetime newest = 0;
  int total = PositionsTotal();
  for (int i = 0; i < total; i++)
  {
    ulong position_ticket = PositionGetTicket(i);
    if (!PositionSelectByTicket(position_ticket))
      continue;

    if (PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber)
      continue;

    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    if (PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      continue;

    double vol = PositionGetDouble(POSITION_VOLUME);
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double profit = PositionGetDouble(POSITION_PROFIT);
    datetime opentm = (datetime)PositionGetInteger(POSITION_TIME);

    s.count++;
    s.totalVolume += vol;
    s.totalInvested += vol * openPrice;
    s.floatingProfit += profit;

    if (opentm > newest)
    {
      newest = opentm;
      s.lastPrice = openPrice;
      s.lastVol = vol;
    }
  }
}

//+------------------------------------------------------------------+
//| Calculates the next lot size to open.                           |
//+------------------------------------------------------------------+
double NextVolume(const Stats &s)
{
  if (s.count == 0)
    return BaseLots;
  if (s.count == 1)
    return BaseLots;
  if (s.count == 2)
    return BaseLots * 2.0;
  else
    return s.lastVol * 2.0;
}

//+------------------------------------------------------------------+
//| Checks if a new order can be opened based on max limits.         |
//+------------------------------------------------------------------+
bool CanOpen(const Stats &s, double v)
{
  if (s.count >= MaxOrders)
    return false;
  if (s.totalVolume + v > MaxTotalLots)
    return false;
  return true;
}

//+------------------------------------------------------------------+
//| Opens a new SELL position.                                       |
//+------------------------------------------------------------------+
bool OpenSell(double volume)
{
  volume = NormalizeVolume(volume);
  if (volume <= 0.0)
    return false;

  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  if (bid <= 0)
    return false;

  MqlTradeRequest r;
  MqlTradeResult res;
  ZeroMemory(r);
  ZeroMemory(res);
  r.action = TRADE_ACTION_DEAL;
  r.symbol = _Symbol;
  r.type = ORDER_TYPE_SELL;
  r.volume = volume;
  r.price = bid;
  r.deviation = Slippage;
  r.magic = MagicNumber;
  r.type_filling = ORDER_FILLING_FOK;

  if (!OrderSend(r, res))
  {
    int e = GetLastError();
    Print("FOK fail ", e, " retry IOC");
    ResetLastError();
    ZeroMemory(r);
    ZeroMemory(res);
    r.action = TRADE_ACTION_DEAL;
    r.symbol = _Symbol;
    r.type = ORDER_TYPE_SELL;
    r.volume = volume;
    r.price = bid;
    r.deviation = Slippage;
    r.magic = MagicNumber;
    r.type_filling = ORDER_FILLING_IOC;
    if (!OrderSend(r, res))
    {
      Print("IOC fail ", GetLastError(), "volume: ", DoubleToString(volume, 2));
      return false;
    }
  }

  if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
  {
    Print("Retcode not DONE ", res.retcode);
    return false;
  }

  last_entry_price = res.price;
  sequence_active = true;

  // UPDATE LOCK: Prevent immediate re-entry on the next tick
  last_trade_time = TimeCurrent();

  Print("Opened SELL ", DoubleToString(volume, 2), " @ ", DoubleToString(res.price, _Digits));
  return true;
}

//+------------------------------------------------------------------+
//| Closes all open SELL positions.                                  |
//+------------------------------------------------------------------+
void CloseAllSells()
{
  int total = PositionsTotal();
  for (int i = total - 1; i >= 0; i--)
  {
    ulong position_ticket = PositionGetTicket(i);
    if (!PositionSelectByTicket(position_ticket))
      continue;

    if (PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber)
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if (PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      continue;

    double vol = PositionGetDouble(POSITION_VOLUME);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    MqlTradeRequest r;
    MqlTradeResult res;
    ZeroMemory(r);
    ZeroMemory(res);
    r.action = TRADE_ACTION_DEAL;
    r.symbol = _Symbol;
    r.type = ORDER_TYPE_BUY; // close SELL by buying
    r.position = position_ticket;
    r.volume = vol;
    r.price = ask;
    r.deviation = Slippage;
    r.magic = MagicNumber;

    if (!OrderSend(r, res))
    {
      Print("Close failed for ticket ", position_ticket, " err:", GetLastError());
    }
    else
    {
      Print("Closed SELL ticket ", position_ticket);
      // Log to server (optional)
      OnTradeClose(position_ticket);
    }
  }
  sequence_active = false;
  last_entry_price = 0.0;
}

//+------------------------------------------------------------------+
//| Checks if the profit target has been reached.                    |
//+------------------------------------------------------------------+
void CheckProfit()
{

  Stats s;
  CollectStats(s);

  if (s.count == 0)
  {
    return;
  }

  // if has only one position and profit target earch
  if (s.count == 1)
  {
    CloseWhenSinglePositionProfit(s);
  }

  double target = s.totalInvested * (ProfitTargetPercent / 100.0);

  if (s.floatingProfit >= target)
  {
    Print("TARGET HIT profit=", DoubleToString(s.floatingProfit, 2),
          " target=", DoubleToString(target, 2));
    CloseAllSells();
    if (AutoRestart)
      Print("AutoRestart pending.");
  }
}

//+------------------------------------------------------------------+
//| Manages the layered entry logic.                                 |
//+------------------------------------------------------------------+
void ManageLayers()
{
  // LOCK CHECK: Exit if still in the cooldown period after a trade attempt
  // Just prevent the duplicate create Position
  if (TimeCurrent() < last_trade_time + TRADE_COOLDOWN_SECONDS)
  {
    return;
  }

  // Step 1: Collect current stats on open positions
  Stats s;
  CollectStats(s);

  // If no positions are open, start a new sequence
  if (s.count == 0)
  {
    if (AutoStartOnInit && !sequence_active)
    {
      // Update lock time before initial sell
      last_trade_time = TimeCurrent();
      OpenSell(BaseLots);
    }
    return;
  }

  // Step 2: Get the last entry price and current ask price
  last_entry_price = s.lastPrice;
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  // Step 3: Define your fixed adverse distance (price moving up against SELL)
  double adverse_threshold = StepsPerLayer;

  // Step 4: Calculate the actual adverse movement in price for SELL (price rising)
  double adverse_movement = ask - last_entry_price;

  // Step 5: Compare and act
  if (adverse_movement >= adverse_threshold)
  {
    // Get the next lot size based on your existing logic
    double nv = NextVolume(s);

    // Check if we can open a new trade based on max limits
    if (CanOpen(s, nv))
    {
      // Update lock time before attempting to open the trade
      last_trade_time = TimeCurrent();
      OpenSell(nv);
    }
  }
}

/// when this algorithm apply and has only single positions
/// and profit earn 1% of my balance
void CloseWhenSinglePositionProfit(Stats &s)
{
  double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
  double target_amount = current_balance * 0.01; // 1% of balance

  // 10 times profits compare to lotsize
  double profitLotsize = s.lastVol * 10;

  if (s.floatingProfit >= profitLotsize)
  {
    Print("TARGET HIT: Floating Profit ($", DoubleToString(s.floatingProfit, 2),
          ") >= Target Amount ($", DoubleToString(target_amount, 2), ")");
    CloseAllSells();
    if (AutoRestart)
      Print("AutoRestart pending.");
  }
}

//--- Example function: log trade on position close
//--- This function just use for log in the future will connect API
void OnTradeClose(ulong ticket)
{
  if (!PositionSelectByTicket(ticket))
    return;
  string type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
  double lots = PositionGetDouble(POSITION_VOLUME);
  string symbol = PositionGetString(POSITION_SYMBOL);
  double open_p = PositionGetDouble(POSITION_PRICE_OPEN);
  datetime open_t = (datetime)PositionGetInteger(POSITION_TIME);
  double close_p = PositionGetDouble(POSITION_PRICE_CURRENT); // or use PositionGetDouble(POSITION_PRICE_CLOSE) if available
  datetime close_t = TimeCurrent();
  double profit = PositionGetDouble(POSITION_PROFIT);

  logger.LogTrade(type, lots, symbol, open_p, open_t, close_p, close_t, profit);
}

//+------------------------------------------------------------------+
//| Expert initialization function.                                  |
//+------------------------------------------------------------------+
int OnInit()
{
  Print("TestLayersEA init (SELL-only).");
  if (AutoStartOnInit)
  {
    Stats s;
    CollectStats(s);
    if (s.count == 0)
      OpenSell(BaseLots);
  }
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function.                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  Print("Deinit reason=", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function.                                            |
//+------------------------------------------------------------------+
void OnTick()
{
  ManageLayers();
  CheckProfit();
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
