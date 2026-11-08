//+------------------------------------------------------------------+
//| GoldSniper_BTCUSD_Test.mq5                                           |
//| Demo-test variant for BTCUSD and other crypto CFD symbols         |
//| Uses EMA crossover + ATR stop; account currency can be ZAR.      |
//| IMPORTANT: Test on DEMO first. This version has no news filter.  |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "Gold Sniper BTCUSD V3 Advanced - EMA/ATR/RSI/ADX"


//--- Trading and risk inputs
input ulong  MagicNumber       = 6112026;
input double RiskPercent       = 1.0;     // Risk as % of equity
input double MaxRiskMoney      = 35.0;    // Maximum account-currency risk per trade (R35 on a ZAR account)
input double RewardRiskRatio  = 5.0;     // Take profit = stop distance x this ratio
input int    FastEMAPeriod     = 20;
input int    SlowEMAPeriod     = 50;
input int    ATRPeriod         = 14;
input double ATRStopMultiplier = 2.0;
input double MaxSpreadPercent = 0.0600;    // Maximum spread as % of BTCUSD mid-price; keep protection enabled
input int    SlippagePoints    = 30;

//--- Advanced entry filters
input bool   UseRSIFilter       = true;
input int    RSIPeriod          = 14;
input double BuyRSIMax          = 68.0;    // Avoid buying when RSI is excessively high
input double SellRSIMin         = 32.0;    // Avoid selling when RSI is excessively low
input bool   UseADXFilter       = true;
input int    ADXPeriod          = 14;
input double MinADX             = 18.0;    // Require a minimum trend-strength reading

//--- Position protection
input bool   UseBreakEven       = true;
input double BreakEvenAtR       = 1.0;     // Move SL toward entry after 1R open profit
input double BreakEvenLockR     = 0.05;    // Lock a small fraction of R, where broker rules allow
input bool   UseTrailingStop    = true;
input double TrailStartR        = 1.5;     // Start ATR trailing after 1.5R open profit
input double TrailATRMultiplier = 1.5;

//--- Daily safety limit (deposit/account currency)
input double MaxDailyLossMoney  = 70.0;    // Stop opening new trades after this day's realized loss

//--- Indicator handles
int fastMAHandle = INVALID_HANDLE;
int slowMAHandle = INVALID_HANDLE;
int atrHandle    = INVALID_HANDLE;
int rsiHandle    = INVALID_HANDLE;
int adxHandle    = INVALID_HANDLE;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(FastEMAPeriod <= 0 || SlowEMAPeriod <= 0 ||
      FastEMAPeriod >= SlowEMAPeriod || ATRPeriod <= 0 ||
      RiskPercent <= 0.0 || MaxRiskMoney <= 0.0 ||
      RewardRiskRatio <= 0.0 || ATRStopMultiplier <= 0.0 ||
      MaxSpreadPercent <= 0.0 || RSIPeriod <= 0 || ADXPeriod <= 0 ||
      BuyRSIMax <= 0.0 || BuyRSIMax >= 100.0 ||
      SellRSIMin <= 0.0 || SellRSIMin >= 100.0 ||
      MinADX < 0.0 || BreakEvenAtR <= 0.0 ||
      BreakEvenLockR < 0.0 || TrailStartR <= 0.0 ||
      TrailATRMultiplier <= 0.0 || MaxDailyLossMoney <= 0.0)
   {
      Print("Gold Sniper BTC: invalid input settings.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle    = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
   rsiHandle    = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   adxHandle    = iADX(_Symbol, PERIOD_CURRENT, ADXPeriod);

   if(fastMAHandle == INVALID_HANDLE ||
      slowMAHandle == INVALID_HANDLE ||
      atrHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
   {
      Print("Gold Sniper BTC: could not create indicator handles. Error: ", GetLastError());
      return(INIT_FAILED);
   }

   Print("Gold Sniper BTC V3 Advanced initialized on ", _Symbol,
         ". ATR stops, RSI/ADX filters, break-even, trailing stop and daily loss guard enabled. ",
         "Risk is calculated in the account deposit currency.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(slowMAHandle);
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   if(adxHandle != INVALID_HANDLE)
      IndicatorRelease(adxHandle);
}

//+------------------------------------------------------------------+
//| Check whether a new chart bar has started                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == 0)
      return(false);

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Check for an existing position opened by this EA                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string positionSymbol = PositionGetString(POSITION_SYMBOL);
      long positionMagic = PositionGetInteger(POSITION_MAGIC);

      if(positionSymbol == _Symbol && (ulong)positionMagic == MagicNumber)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Calculate volume from the cash risk and stop distance           |
//+------------------------------------------------------------------+
double CalculateVolume(const double stopDistance)
{
   if(stopDistance <= 0.0)
      return(0.0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = MathMin(equity * RiskPercent / 100.0, MaxRiskMoney);

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(riskMoney <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0 ||
      minVolume <= 0.0 || maxVolume <= 0.0 || volumeStep <= 0.0)
      return(0.0);

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return(0.0);

   double volume = riskMoney / lossPerLot;
   volume = MathMin(volume, maxVolume);
   volume = MathFloor(volume / volumeStep) * volumeStep;
   volume = NormalizeDouble(volume, 8);

   // Do not force the broker's minimum lot if it would exceed the risk cap.
   if(volume < minVolume)
      return(0.0);

   return(volume);
}

//+------------------------------------------------------------------+
//| Send a market order without the Trade.mqh library                |
//+------------------------------------------------------------------+
bool SendMarketOrder(const ENUM_ORDER_TYPE orderType, const double volume,
                     const double sl, const double tp, const string comment)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return(false);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.magic        = MagicNumber;
   request.volume       = volume;
   request.type         = orderType;
   request.price        = (orderType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   request.sl           = sl;
   request.tp           = tp;
   request.deviation    = SlippagePoints;
   long fillingModes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingModes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_FOK;
   request.comment      = comment;

   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_DONE &&
                result.retcode != TRADE_RETCODE_PLACED &&
                result.retcode != TRADE_RETCODE_DONE_PARTIAL))
   {
      Print("Gold Sniper BTC order failed. Retcode: ", result.retcode,
            " - ", result.comment, " Error: ", GetLastError());
      return(false);
   }

   Print("Gold Sniper BTC order accepted. Ticket: ", result.order,
         " Deal: ", result.deal);
   return(true);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Sum today's closed P/L for this EA and symbol                    |
//+------------------------------------------------------------------+
double TodayClosedProfit()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart, TimeCurrent()))
      return(0.0);

   double total = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber)
         continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      {
         total += HistoryDealGetDouble(deal, DEAL_PROFIT);
         total += HistoryDealGetDouble(deal, DEAL_SWAP);
         total += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      }
   }
   return(total);
}

//+------------------------------------------------------------------+
//| Change position stop loss while preserving take profit           |
//+------------------------------------------------------------------+
bool ModifyPositionSL(const ulong ticket, const double newSL, const double tp)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = _Symbol;
   request.magic = MagicNumber;
   request.sl = newSL;
   request.tp = tp;

   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_DONE &&
                result.retcode != TRADE_RETCODE_NO_CHANGES))
   {
      Print("Gold Sniper BTC: SL modification failed. Retcode: ",
            result.retcode, " - ", result.comment);
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Break-even and ATR trailing management                           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double atrNow[];
   ArrayResize(atrNow, 1);
   ArraySetAsSeries(atrNow, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrNow) != 1 || atrNow[0] <= 0.0)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDistance = MathMax(
      (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point,
      (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      bool isBuy = (type == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double initialRisk = MathAbs(openPrice - currentSL);
      if(currentTP > 0.0 && RewardRiskRatio > 0.0)
         initialRisk = MathAbs(currentTP - openPrice) / RewardRiskRatio;
      if(initialRisk <= 0.0)
         continue;

      double marketPrice = isBuy ? tick.bid : tick.ask;
      double profitDistance = isBuy ? marketPrice - openPrice : openPrice - marketPrice;
      double candidateSL = currentSL;
      bool change = false;

      if(UseBreakEven && profitDistance >= initialRisk * BreakEvenAtR)
      {
         double beSL = isBuy ? openPrice + initialRisk * BreakEvenLockR
                             : openPrice - initialRisk * BreakEvenLockR;
         if((isBuy && (currentSL == 0.0 || beSL > candidateSL)) ||
            (!isBuy && (currentSL == 0.0 || beSL < candidateSL)))
         {
            candidateSL = beSL;
            change = true;
         }
      }

      if(UseTrailingStop && profitDistance >= initialRisk * TrailStartR)
      {
         double trailSL = isBuy ? marketPrice - atrNow[0] * TrailATRMultiplier
                                : marketPrice + atrNow[0] * TrailATRMultiplier;
         if((isBuy && trailSL > candidateSL) ||
            (!isBuy && (candidateSL == 0.0 || trailSL < candidateSL)))
         {
            candidateSL = trailSL;
            change = true;
         }
      }

      if(!change)
         continue;

      if(isBuy)
      {
         candidateSL = MathMin(candidateSL, tick.bid - minDistance);
         if(candidateSL <= currentSL || candidateSL <= 0.0)
            continue;
      }
      else
      {
         candidateSL = MathMax(candidateSL, tick.ask + minDistance);
         if(currentSL > 0.0 && candidateSL >= currentSL)
            continue;
      }

      candidateSL = NormalizeDouble(candidateSL, digits);
      ModifyPositionSL(ticket, candidateSL, currentTP);
   }
}

void OnTick()
{
   // Manage protective stops on every tick, not only once per candle.
   ManageOpenPositions();

   if(!IsNewBar())
      return;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   double todayProfit = TodayClosedProfit();
   if(todayProfit <= -MaxDailyLossMoney)
   {
      Print("Gold Sniper BTC: daily loss limit reached (",
            DoubleToString(todayProfit, 2), "). No new trades today.");
      return;
   }

   if(HasOpenPosition())
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;

   double midPrice = (tick.ask + tick.bid) / 2.0;
   if(midPrice <= 0.0)
      return;

   double spreadPercent = ((tick.ask - tick.bid) / midPrice) * 100.0;
   if(spreadPercent > MaxSpreadPercent)
   {
      Print("Gold Sniper BTC: spread too high (",
            DoubleToString(spreadPercent, 4), "%; limit ",
            DoubleToString(MaxSpreadPercent, 4), "%). No trade.");
      return;
   }

   double fast[];
   double slow[];
   double atr[];
   double rsi[];
   double adx[];
   ArrayResize(fast, 3);
   ArrayResize(slow, 3);
   ArrayResize(atr, 3);
   ArrayResize(rsi, 3);
   ArrayResize(adx, 3);
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(fastMAHandle, 0, 0, 3, fast) < 3 ||
      CopyBuffer(slowMAHandle, 0, 0, 3, slow) < 3 ||
      CopyBuffer(atrHandle, 0, 0, 3, atr) < 3 ||
      CopyBuffer(rsiHandle, 0, 0, 3, rsi) < 3 ||
      CopyBuffer(adxHandle, 0, 0, 3, adx) < 3)
   {
      Print("Gold Sniper BTC: waiting for indicator data.");
      return;
   }

   // Use the two completed candles to avoid acting on a changing candle.
   bool buySignal  = (fast[2] <= slow[2] && fast[1] > slow[1]);
   bool sellSignal = (fast[2] >= slow[2] && fast[1] < slow[1]);

   // Confirm EMA crossover with RSI and ADX on the last completed candle.
   if(buySignal && UseRSIFilter && rsi[1] > BuyRSIMax)
      buySignal = false;
   if(sellSignal && UseRSIFilter && rsi[1] < SellRSIMin)
      sellSignal = false;
   if(UseADXFilter && adx[1] < MinADX)
   {
      buySignal = false;
      sellSignal = false;
   }

   if(!buySignal && !sellSignal)
      return;

   double stopDistance = atr[1] * ATRStopMultiplier;
   if(stopDistance <= 0.0)
      return;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minimumStopDistance = (double)stopsLevel * point;
   if(stopDistance < minimumStopDistance)
      stopDistance = minimumStopDistance;

   double volume = CalculateVolume(stopDistance);
   if(volume <= 0.0)
   {
      Print("Gold Sniper BTC: calculated volume is below broker minimum or symbol risk data is unavailable. No trade.");
      return;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = 0.0;
   double tp = 0.0;
   bool sent = false;

   if(buySignal)
   {
      sl = NormalizeDouble(tick.ask - stopDistance, digits);
      tp = NormalizeDouble(tick.ask + stopDistance * RewardRiskRatio, digits);
      sent = SendMarketOrder(ORDER_TYPE_BUY, volume, sl, tp, "Gold Sniper EMA buy");
   }
   else if(sellSignal)
   {
      sl = NormalizeDouble(tick.bid + stopDistance, digits);
      tp = NormalizeDouble(tick.bid - stopDistance * RewardRiskRatio, digits);
      sent = SendMarketOrder(ORDER_TYPE_SELL, volume, sl, tp, "Gold Sniper EMA sell");
   }

   if(sent)
      Print("Gold Sniper BTC order sent. Volume: ", volume,
            " SL: ", sl, " TP: ", tp);
}
//+------------------------------------------------------------------+
