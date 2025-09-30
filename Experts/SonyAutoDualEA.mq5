//+------------------------------------------------------------------+
//| SonyAutoDualEA.mq5 - Run BUY and SELL algorithms together        |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

// Logger toggle (disabled by default; set to 1 to enable HTTP logging)
#define USE_HTTP_LOGGER 0
#if defined(USE_HTTP_LOGGER) && (USE_HTTP_LOGGER == 1)
#include <SonyTradeLogger.mqh>
#endif

//--- Inputs Https server api
input string TradeLogAPI_URL = "https://your-server.com/api/save_trade";
input int WebRequestTimeout = 10000;

//--- Strategy enable toggles
input bool EnableBuy = true;
input bool EnableSell = true;

//--- Trading Inputs (shared)
input double BaseLots = 0.01;
input double StepSize = 1.0;
input int StepsPerLayer = 5;
input double ProfitTargetPercent = 20.0;
input int Slippage = 10;
input int MaxOrders = 15;
input double MaxTotalLots = 1.0;
input bool AutoRestart = true;
input bool AutoStartOnInit = true;

//--- Magic numbers (distinct per side)
input ulong MagicNumberBuy = 2025091901;
input ulong MagicNumberSell = 2025091902;

//--- Global State per side
struct SideState
{
    double last_entry_price;
    bool sequence_active;
    datetime last_trade_time;
};
SideState buyState = {0.0, false, 0};
SideState sellState = {0.0, false, 0};

const int TRADE_COOLDOWN_SECONDS = 5; // Wait 5 seconds after a trade attempt

#if defined(USE_HTTP_LOGGER) && (USE_HTTP_LOGGER == 1)
SonyTradeLogger logger(TradeLogAPI_URL, WebRequestTimeout);
#endif

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

    vol = MathMax(vmin, MathMin(vol, vmax));
    vol = MathRound(vol / step) * step;
    return NormalizeDouble(vol, (int)MathRound(-log10(step)));
}

//+------------------------------------------------------------------+
//| Collects statistics by side (BUY/SELL) using provided magic      |
//+------------------------------------------------------------------+
void CollectStats(Stats &s, bool forBuy, ulong magic)
{
    ZeroMemory(s);
    datetime newest = 0;
    int total = PositionsTotal();
    for (int i = 0; i < total; i++)
    {
        ulong position_ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(position_ticket))
            continue;

        if (PositionGetInteger(POSITION_MAGIC) != (long)magic)
            continue;

        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        long ptype = PositionGetInteger(POSITION_TYPE);
        if (forBuy && ptype != POSITION_TYPE_BUY)
            continue;
        if (!forBuy && ptype != POSITION_TYPE_SELL)
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

double NextVolume(const Stats &s)
{
    if (s.count == 0)
        return BaseLots;
    if (s.count == 1)
        return BaseLots;
    if (s.count == 2)
        return BaseLots * 2.0;
    return s.lastVol * 2.0;
}

bool CanOpen(const Stats &s, double v)
{
    if (s.count >= MaxOrders)
        return false;
    if (s.totalVolume + v > MaxTotalLots)
        return false;
    return true;
}

bool OpenBuy(double volume, ulong magic)
{
    volume = NormalizeVolume(volume);
    if (volume <= 0.0)
        return false;
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if (ask <= 0)
        return false;

    MqlTradeRequest r;
    MqlTradeResult res;
    ZeroMemory(r);
    ZeroMemory(res);
    r.action = TRADE_ACTION_DEAL;
    r.symbol = _Symbol;
    r.type = ORDER_TYPE_BUY;
    r.volume = volume;
    r.price = ask;
    r.deviation = Slippage;
    r.magic = magic;
    r.type_filling = ORDER_FILLING_FOK;

    if (!OrderSend(r, res))
    {
        ResetLastError();
        ZeroMemory(r);
        ZeroMemory(res);
        r.action = TRADE_ACTION_DEAL;
        r.symbol = _Symbol;
        r.type = ORDER_TYPE_BUY;
        r.volume = volume;
        r.price = ask;
        r.deviation = Slippage;
        r.magic = magic;
        r.type_filling = ORDER_FILLING_IOC;
        if (!OrderSend(r, res))
            return false;
    }
    if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
        return false;
    Print("Opened BUY ", DoubleToString(volume, 2), " @ ", DoubleToString(res.price, _Digits));
    return true;
}

bool OpenSell(double volume, ulong magic)
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
    r.magic = magic;
    r.type_filling = ORDER_FILLING_FOK;

    if (!OrderSend(r, res))
    {
        ResetLastError();
        ZeroMemory(r);
        ZeroMemory(res);
        r.action = TRADE_ACTION_DEAL;
        r.symbol = _Symbol;
        r.type = ORDER_TYPE_SELL;
        r.volume = volume;
        r.price = bid;
        r.deviation = Slippage;
        r.magic = magic;
        r.type_filling = ORDER_FILLING_IOC;
        if (!OrderSend(r, res))
            return false;
    }
    if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
        return false;
    Print("Opened SELL ", DoubleToString(volume, 2), " @ ", DoubleToString(res.price, _Digits));
    return true;
}

void CloseAllBuys(ulong magic)
{
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; --i)
    {
        ulong position_ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(position_ticket))
            continue;
        if (PositionGetInteger(POSITION_MAGIC) != (long)magic)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if (PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
            continue;

        double vol = PositionGetDouble(POSITION_VOLUME);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        MqlTradeRequest r;
        MqlTradeResult res;
        ZeroMemory(r);
        ZeroMemory(res);
        r.action = TRADE_ACTION_DEAL;
        r.symbol = _Symbol;
        r.type = ORDER_TYPE_SELL;
        r.position = position_ticket;
        r.volume = vol;
        r.price = bid;
        r.deviation = Slippage;
        r.magic = magic;
        if (OrderSend(r, res))
        {
            Print("Closed BUY ticket ", position_ticket);
            OnTradeClose(position_ticket);
        }
    }
}

void CloseAllSells(ulong magic)
{
    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; --i)
    {
        ulong position_ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(position_ticket))
            continue;
        if (PositionGetInteger(POSITION_MAGIC) != (long)magic)
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
        r.magic = magic;
        if (OrderSend(r, res))
        {
            Print("Closed SELL ticket ", position_ticket);
            OnTradeClose(position_ticket);
        }
    }
}

void CheckProfitAndClose(const Stats &s, bool forBuy, ulong magic)
{
    if (s.count == 0)
        return;
    double target = s.totalInvested * (ProfitTargetPercent / 100.0);
    if (s.floatingProfit >= target)
    {
        Print("TARGET HIT profit=", DoubleToString(s.floatingProfit, 2),
              " target=", DoubleToString(target, 2));
        if (forBuy)
            CloseAllBuys(magic);
        else
            CloseAllSells(magic);
    }
}

void CloseWhenSinglePositionProfit(Stats &s, bool forBuy, ulong magic)
{
    if (s.count != 1)
        return;
    double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double target_amount = current_balance * 0.01; // 1% of balance
    double profitLotsize = s.lastVol * 10;         // keep original behavior
    if (s.floatingProfit >= profitLotsize)
    {
        Print("TARGET HIT: Floating Profit ($", DoubleToString(s.floatingProfit, 2),
              ") >= Target Amount ($", DoubleToString(target_amount, 2), ")");
        if (forBuy)
            CloseAllBuys(magic);
        else
            CloseAllSells(magic);
    }
}

//--- Example function: log trade on position close
void OnTradeClose(ulong ticket)
{
    if (!PositionSelectByTicket(ticket))
        return;
    string type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
    double lots = PositionGetDouble(POSITION_VOLUME);
    string symbol = PositionGetString(POSITION_SYMBOL);
    double open_p = PositionGetDouble(POSITION_PRICE_OPEN);
    datetime open_t = (datetime)PositionGetInteger(POSITION_TIME);
    double close_p = PositionGetDouble(POSITION_PRICE_CURRENT);
    datetime close_t = TimeCurrent();
    double profit = PositionGetDouble(POSITION_PROFIT);

#if defined(USE_HTTP_LOGGER) && (USE_HTTP_LOGGER == 1)
    logger.LogTrade(type, lots, symbol, open_p, open_t, close_p, close_t, profit);
#endif
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("SonyAutoDualEA init.");
    if (AutoStartOnInit)
    {
        if (EnableBuy)
        {
            Stats sb;
            CollectStats(sb, true, MagicNumberBuy);
            if (sb.count == 0)
            {
                buyState.last_trade_time = TimeCurrent();
                if (OpenBuy(BaseLots, MagicNumberBuy))
                    buyState.sequence_active = true;
            }
        }
        if (EnableSell)
        {
            Stats ss;
            CollectStats(ss, false, MagicNumberSell);
            if (ss.count == 0)
            {
                sellState.last_trade_time = TimeCurrent();
                if (OpenSell(BaseLots, MagicNumberSell))
                    sellState.sequence_active = true;
            }
        }
    }
    return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("Deinit reason=", reason);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
    // BUY side management
    if (EnableBuy)
    {
        if (TimeCurrent() >= buyState.last_trade_time + TRADE_COOLDOWN_SECONDS)
        {
            Stats s;
            CollectStats(s, true, MagicNumberBuy);
            if (s.count == 0)
            {
                if (!buyState.sequence_active && AutoStartOnInit)
                {
                    buyState.last_trade_time = TimeCurrent();
                    if (OpenBuy(BaseLots, MagicNumberBuy))
                        buyState.sequence_active = true;
                }
            }
            else
            {
                // Layer logic for BUY: adverse when price falls
                buyState.last_entry_price = s.lastPrice;
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                double adverse_threshold = StepsPerLayer;
                double adverse_movement = buyState.last_entry_price - bid;
                if (adverse_movement >= adverse_threshold)
                {
                    double nv = NextVolume(s);
                    if (CanOpen(s, nv))
                    {
                        buyState.last_trade_time = TimeCurrent();
                        OpenBuy(nv, MagicNumberBuy);
                    }
                }
                CloseWhenSinglePositionProfit(s, true, MagicNumberBuy);
                CheckProfitAndClose(s, true, MagicNumberBuy);
            }
        }
    }

    // SELL side management
    if (EnableSell)
    {
        if (TimeCurrent() >= sellState.last_trade_time + TRADE_COOLDOWN_SECONDS)
        {
            Stats s;
            CollectStats(s, false, MagicNumberSell);
            if (s.count == 0)
            {
                if (!sellState.sequence_active && AutoStartOnInit)
                {
                    sellState.last_trade_time = TimeCurrent();
                    if (OpenSell(BaseLots, MagicNumberSell))
                        sellState.sequence_active = true;
                }
            }
            else
            {
                // Layer logic for SELL: adverse when price rises
                sellState.last_entry_price = s.lastPrice;
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                double adverse_threshold = StepsPerLayer;
                double adverse_movement = ask - sellState.last_entry_price;
                if (adverse_movement >= adverse_threshold)
                {
                    double nv = NextVolume(s);
                    if (CanOpen(s, nv))
                    {
                        sellState.last_trade_time = TimeCurrent();
                        OpenSell(nv, MagicNumberSell);
                    }
                }
                CloseWhenSinglePositionProfit(s, false, MagicNumberSell);
                CheckProfitAndClose(s, false, MagicNumberSell);
            }
        }
    }
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
