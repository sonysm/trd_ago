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
input double ProfitTargetPercent = 25.0;
input int MaxOrders = 15;
input double MaxTotalLots = 10.0;
input bool AutoBalancing = true;

input bool AutoRestart = true;
input bool AutoStartOnInit = true;

//--- Magic numbers (distinct per side)
input ulong MagicNumberBuy = 2025091901;
input ulong MagicNumberSell = 2025091902;

// Global ------
long accountId = (long)AccountInfoInteger(ACCOUNT_LOGIN);
double g_min_floating_pl = 0.0; // most negative floating P/L

// Private variable
const ulong MagicNumberHelp = 2025091903;

//--- Global State per side
struct SideState
{
    double last_entry_price;
    bool sequence_active;
    datetime last_trade_time;
};
SideState buyState = {0.0, false, 0};
SideState sellState = {0.0, false, 0};

const int TRADE_COOLDOWN_SECONDS = 2; // Wait 5 seconds after a trade attempt

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

/// This mean  profit and state Include all [BUY, SELL and HELP]
/// total [invest] all and [count] all
// [Note] we use Stats struct but use only Floating profit property only
Stats CollectAllPositionState()
{
    Stats s;
    ZeroMemory(s);
    datetime newest = 0;

    int total = PositionsTotal();
    for (int i = 0; i < total; i++)
    {
        ulong position_ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(position_ticket))
            continue;

        long magic = PositionGetInteger(POSITION_MAGIC);
        if (magic != (long)MagicNumberBuy && magic != (long)MagicNumberSell && magic != (long)MagicNumberHelp)
            continue;

        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        double vol = PositionGetDouble(POSITION_VOLUME);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double profit = PositionGetDouble(POSITION_PROFIT);
        s.floatingProfit += profit;
        s.count += 1;
        s.totalInvested = vol * openPrice;
    }

    return s;
}

//+------------------------------------------------------------------+
//| Collects statistics by side (BUY/SELL) using provided magic      |
//+------------------------------------------------------------------+
void CollectStats(Stats &s, bool forBuy, ulong magic)
{
    ZeroMemory(s);
    int total = PositionsTotal();

    // Track the two largest volumes; if equal volume, prefer the newest by time
    double maxVol1 = -1.0, maxVol2 = -1.0;
    datetime maxTime1 = 0, maxTime2 = 0;
    double maxVol1OpenPrice = 0.0;

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

        // Update top-2 volumes
        if (vol > maxVol1 || (vol == maxVol1 && opentm > maxTime1))
        {
            // Shift current max to second
            maxVol2 = maxVol1;
            maxTime2 = maxTime1;

            // Set new max
            maxVol1 = vol;
            maxTime1 = opentm;
            maxVol1OpenPrice = openPrice;
        }
        else if (vol > maxVol2 || (vol == maxVol2 && opentm > maxTime2))
        {
            maxVol2 = vol;
            maxTime2 = opentm;
        }
    }

    // Assign last/previous volumes and lastPrice based on largest lotsize
    if (maxVol1 > 0.0)
    {
        s.lastVol = maxVol1;
        s.lastPrice = maxVol1OpenPrice; // price of the position with biggest lotsize
    }
    if (maxVol2 > 0.0)
    {
        s.previousVol = maxVol2;
    }
}

double NextVolume(const Stats &s)
{
    double nextVol = s.previousVol + s.lastVol;
    return nextVol;
}

bool CanOpen(const Stats &s, double volume)
{
    if (s.count >= MaxOrders)
        return false;
    if (s.totalVolume + volume > MaxTotalLots)
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
    r.deviation = SmartDeviationPoints(_Symbol);
    r.magic = magic;
    r.type_filling = ORDER_FILLING_FOK;

    if (!OrderSend(r, res))
    {
        PrintFormat("ERROR OPEN BUY lotsize=%.2f price=%.2f", volume, ask);
        ResetLastError();
        ZeroMemory(r);
        ZeroMemory(res);
        r.action = TRADE_ACTION_DEAL;
        r.symbol = _Symbol;
        r.type = ORDER_TYPE_BUY;
        r.volume = volume;
        r.price = ask;
        r.deviation = SmartDeviationPoints(_Symbol);
        r.magic = magic;
        r.type_filling = ORDER_FILLING_IOC;
        if (!OrderSend(r, res))
            PrintFormat("ERROR OPEN BUY lotsize=%.2f price=%.2f", volume, ask);
        return false;
    }
    if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
        return false;
    Print("Opened BUY ", DoubleToString(volume, 2), " @ ", DoubleToString(res.price, _Digits), " Ticket=", IntegerToString(res.order));
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
    r.deviation = SmartDeviationPoints(_Symbol);
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
        r.deviation = SmartDeviationPoints(_Symbol);
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

void CloseAll()
{
    // Hold new Position BUY temp
    buyState.sequence_active = true;

    // Hold new Position SELL temp
    sellState.sequence_active = true;

    int total = PositionsTotal();
    for (int i = total - 1; i >= 0; --i)
    {
        ulong position_ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(position_ticket))
            continue;

        // not my record
        long magic = PositionGetInteger(POSITION_MAGIC);
        if (magic != (long)MagicNumberBuy && magic != (long)MagicNumberSell && magic != (long)MagicNumberHelp)
            continue;

        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        double vol = PositionGetDouble(POSITION_VOLUME);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        long position_type = PositionGetInteger(POSITION_TYPE);

        MqlTradeRequest r;
        MqlTradeResult res;
        ZeroMemory(r);
        ZeroMemory(res);
        r.action = TRADE_ACTION_DEAL;
        r.symbol = _Symbol;
        r.type = position_type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
        r.position = position_ticket;
        r.volume = vol;
        r.price = bid;
        r.deviation = SmartDeviationPoints(_Symbol);
        r.magic = magic;
        if (OrderSend(r, res))
        {
            // Print("Closed BUY ticket ", position_ticket);
            OnTradeClose(position_ticket);
        }
    } // for loop positions

    // Reset BUY-side runtime state so EA can start a fresh sequence
    buyState.sequence_active = false;
    buyState.last_entry_price = 0.0;
    // Nudge last_trade_time back so ManageLayers can immediately open a new starter position
    buyState.last_trade_time = TimeCurrent() - TRADE_COOLDOWN_SECONDS;

    // Reset SEL-side runtime
    sellState.sequence_active = false;
    sellState.last_entry_price = 0.0;
    // Nudge last_trade_time back so ManageLayers can immediately open a new starter position
    sellState.last_trade_time = TimeCurrent() - TRADE_COOLDOWN_SECONDS;
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
        r.deviation = SmartDeviationPoints(_Symbol);
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
        r.deviation = SmartDeviationPoints(_Symbol);
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

    double invested = 0.0, floatingProfit = 0.0;
    int positionCount = 0;
    bool isProfit = false;
    GetAllInvestStatus(invested, floatingProfit, positionCount, isProfit);

    if (!isProfit && positionCount <= 2)
        return;

    if (isProfit && positionCount <= 2)
    {
        // moment 4 times profit of lotsize
        // if 5 times other will create new record
        double tg = 4.5 * BaseLots * 100;
        if (floatingProfit >= tg)
        {
            CloseAll();
            // Reset data
            InitMaxLostProfit();

            return;
        }
    }

    // double max_floating_loss_abs = (g_min_floating_pl < 0.0) ? -g_min_floating_pl : 0.0;
    // double target = max_floating_loss_abs * 0.25;

    // Profit percentage Exmple 25%
    double target = (floatingProfit - g_min_floating_pl) * (ProfitTargetPercent / 100);

    if (floatingProfit >= target)
    {
        PrintFormat("Foating Profit=%.2f, Max-FPL=%.2f, Taget=%.2f", floatingProfit, g_min_floating_pl, target);

        CloseAll();

        // Reset data
        InitMaxLostProfit();
    }
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
    // sh state help magic number
    State allS = CollectAllPositionState();

    positionsCount = allS.count;
    totalInvested = allS.totalInvested;
    floatingProfit = allS.floatingProfit;
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
    g_min_floating_pl = 0.0;
}

/// Check Profit during Trade
void checkMaxLostProfit()
{
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    double fpl = eq - bal; // floating P/L across all open positions

    // Track worst floating P/L (most negative)
    if (fpl < g_min_floating_pl)
    {
        g_min_floating_pl = fpl;
        PrintFormat("Max float profit lost=%.2f", g_min_floating_pl);
    }

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
                OpenBuy(BaseLots, MagicNumberBuy);
            }
        }
        if (EnableSell)
        {
            Stats ss;
            CollectStats(ss, false, MagicNumberSell);
            if (ss.count == 0)
            {
                sellState.last_trade_time = TimeCurrent();
                OpenSell(BaseLots, MagicNumberSell);
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
                    OpenBuy(BaseLots, MagicNumberBuy);
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
                        if (OpenBuy(nv, MagicNumberBuy))
                        {
                            /// Balancing Profit lose
                            if (AutoBalancing)
                            {
                                OpenSell(BaseLots, MagicNumberHelp);
                            }
                        }
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
                    OpenSell(BaseLots, MagicNumberSell);
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
                        if (OpenSell(nv, MagicNumberSell))
                        {
                            /// Balancing Profit lose
                            if (AutoBalancing)
                            {
                                OpenBuy(BaseLots, MagicNumberHelp);
                            }
                        }
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
