//+------------------------------------------------------------------+
//| SonyAutoDualEA.mq5 - Run BUY and SELL algorithms together        |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

// Logger include (always enabled)
#include <SonyTradeLogger.mqh>
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

// Global ------
long accountId = (long)AccountInfoInteger(ACCOUNT_LOGIN);

// Globals
double g_equity_peak = 0.0;
double g_max_drawdown = 0.0;    // in account currency
double g_min_floating_pl = 0.0; // most negative floating P/L

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

SonyTradeLogger logger(TradeLogAPI_URL, WebRequestTimeout);

struct Stats
{
    int count;
    double totalVolume;
    double totalInvested;
    double floatingProfit;
    double lastPrice;
    double previousVol;
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

    // just for next stept in func NextVolume()
    double previousVol = 0;

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
            s.previousVol = s.lastVol;
            s.lastVol = vol;
        }
    }
}

double NextVolume(const Stats &s)
{

    if (s.count <= 2)
    {
        return BaseLots;
    }

    double nextVol = s.previousVol + s.lastVol;
    return nextVol;
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
    r.deviation = SmartDeviationPoints(_Symbol, 10, 3.0);
    r.magic = magic;
    r.type_filling = ORDER_FILLING_FOK;

    if (!OrderSend(r, res))
    {
        Print("Opened SELL ", DoubleToString(volume, 2), " @ ", DoubleToString(res.price, _Digits));
        Print("OPEN SELL ERROR 1: retcode_ex: ", res.retcode_external, " err: ", GetLastError());
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
        {
            Print("OPEN SELL ERROR 2: retcode: ", res.retcode, " err: ", GetLastError());
            return false;
        }
    }
    if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
    {
        Print("OPEN SELL ERROR 2: ", res.retcode);
        return false;
    }
    Print("Opened SELL ", DoubleToString(volume, 2), " @ ", DoubleToString(res.price, _Digits));
    return true;
}

int SmartDeviationPoints(string symbol, int min_points = 10, double spread_multiplier = 3.0)
{
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    if (point <= 0.0 || bid <= 0.0 || ask <= 0.0)
        return min_points; // fallback

    int spread_pts = (int)MathRound((ask - bid) / point);
    int dev = (int)MathMax(min_points, spread_pts * spread_multiplier);
    return dev;
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
    // Reset BUY-side runtime state so EA can start a fresh sequence
    if (magic == MagicNumberBuy)
    {
        buyState.sequence_active = false;
        buyState.last_entry_price = 0.0;
        // Nudge last_trade_time back so ManageLayers can immediately open a new starter position
        buyState.last_trade_time = TimeCurrent() - TRADE_COOLDOWN_SECONDS;
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
    // Reset SELL-side runtime state so EA can start a fresh sequence
    if (magic == MagicNumberSell)
    {
        sellState.sequence_active = false;
        sellState.last_entry_price = 0.0;
        // Nudge last_trade_time back so ManageLayers can immediately open a new starter position
        sellState.last_trade_time = TimeCurrent() - TRADE_COOLDOWN_SECONDS;
    }
}

void CheckProfitAndClose(const Stats &s, bool forBuy, ulong magic)
{
    if (s.count == 0)
        return;

    /// ---------OLD---------///

    double invested = 0.0, profit = 0.0;
    int cnt = 0;
    bool isProfit = false;
    GetAllInvestStatus(invested, profit, cnt, isProfit);

    if (!isProfit && cnt <= 2)
        return;

    if (isProfit && cnt <= 2)
    {
        // 4.up $ it mean 4-5 times if 5 up mean must cnt bigger then 2
        if (profit >= 4)
        {
            CloseAllBuys(magic);
            CloseAllSells(magic);
            // Reset data
            InitMaxLostProfit();
        }
    }

    double max_floating_loss_abs = (g_min_floating_pl < 0.0) ? -g_min_floating_pl : 0.0;
    double target = max_floating_loss_abs * 0.25;
    if (s.floatingProfit >= target)
    {
        PrintFormat("FP=%.2f, MaxDD=%.2f, MinFPL=%.2f", s.floatingProfit, g_max_drawdown, g_min_floating_pl);
        Print("TARGET HIT profit=", DoubleToString(s.floatingProfit, 2),
              " target=", DoubleToString(target, 2));

        CloseAllBuys(magic);
        CloseAllSells(magic);

        // Reset data
        InitMaxLostProfit();
    }

    /// --------- OLD ----------- ////

    // news stragtegy
    //    double invested = 0.0, profit = 0.0;
    //    int cnt = 0;
    //    bool isProfit = false;
    //    GetAllInvestStatus(invested, profit, cnt, isProfit);
    //
    //    if (isProfit)
    //    {
    //        if (profit == BaseLots * 10)
    //        {
    //            CloseAllBuys(MagicNumberBuy);
    //            CloseAllSells(MagicNumberSell);
    //        }
    //    }
}

void CloseWhenSinglePositionProfit(Stats &s, bool forBuy, ulong magic)
{
    if (s.count != 1)
        return;
    double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double target_amount = current_balance * 0.01; // 1% of balance
    // Convert "10 times lotsize" into a currency target using the symbol tick value
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    if (tick_value <= 0.0)
        tick_value = 0.0;                                         // guard
    double profitLotsizeCurrency = s.lastVol * 10.0 * tick_value; // approximate currency value

    // Use whichever target is larger: 1% balance or lotsize-derived currency target
    double effective_target = MathMax(target_amount, profitLotsizeCurrency);

    if (s.floatingProfit >= effective_target)
    {
        Print("TARGET HIT: Floating Profit ($", DoubleToString(s.floatingProfit, 2),
              ") >= Effective Target ($", DoubleToString(effective_target, 2), ")");
        if (forBuy)
            CloseAllBuys(magic);
        else
            CloseAllSells(magic);
    }
}

void GetAllInvestStatus(double &totalInvested, double &floatingProfit, int &positionsCount, bool &isProfit)
{
    Stats sb, ss;
    CollectStats(sb, true, MagicNumberBuy);
    CollectStats(ss, false, MagicNumberSell);

    positionsCount = sb.count + ss.count;
    totalInvested = sb.totalInvested + ss.totalInvested;
    floatingProfit = sb.floatingProfit + ss.floatingProfit;
    isProfit = (floatingProfit >= 0.0);
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

    logger.LogTrade(type, lots, symbol, open_p, open_t, close_p, close_t, profit);
}

/// Check Profit during Trade
void InitMaxLostProfit()
{
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    g_equity_peak = eq;
    g_max_drawdown = 0.0;
    g_min_floating_pl = 0.0;
}

/// Check Profit during Trade
void checkMaxLostProfit()
{
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    double fpl = eq - bal; // floating P/L across all open positions

    // Track equity peak
    if (eq > g_equity_peak)
        g_equity_peak = eq;

    // Update drawdown from peak
    double dd = g_equity_peak - eq;
    if (dd > g_max_drawdown)
        g_max_drawdown = dd;

    // Track worst floating P/L (most negative)
    if (fpl < g_min_floating_pl)
        g_min_floating_pl = fpl;

    // Optional: print occasionally
    // PrintFormat("FPL=%.2f, MaxDD=%.2f, MinFPL=%.2f", fpl, g_max_drawdown, g_min_floating_pl);
}

string Key(string name, long magic)
{
    return StringFormat("%s|%I64d|%s|%I64d",
                        MQLInfoString(MQL_PROGRAM_NAME), AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, magic) +
           "|" + name;
}

void SaveState(long magic, double equity_peak, double worst_fpl)
{
    GlobalVariableSet(Key("equity_peak", magic), equity_peak);
    GlobalVariableSet(Key("worst_fpl", magic), worst_fpl);
}

bool LoadState(long magic, double &equity_peak, double &worst_fpl)
{
    bool ok = true;
    double v;
    ok &= GlobalVariableGet(Key("equity_peak", magic), v);
    if (ok)
        equity_peak = v;
    ok &= GlobalVariableGet(Key("worst_fpl", magic), v);
    if (ok)
        worst_fpl = v;
    return ok;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("SonyAutoDualEA init.");

    InitMaxLostProfit();

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
                {
                    // buyState.sequence_active = true;
                }
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
                {
                    // sellState.sequence_active = true;
                }
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

    // Update profit max lost during Trading
    checkMaxLostProfit();

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
                    {
                        // buyState.sequence_active = true;
                    }
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
                // CloseWhenSinglePositionProfit(s, true, MagicNumberBuy);
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
                    {
                        // sellState.sequence_active = true;
                    }
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
                        Print("can open SELL:");
                        sellState.last_trade_time = TimeCurrent();
                        OpenSell(nv, MagicNumberSell);
                    }
                }
                // CloseWhenSinglePositionProfit(s, false, MagicNumberSell);
                CheckProfitAndClose(s, false, MagicNumberSell);
            }
        }
    }
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
