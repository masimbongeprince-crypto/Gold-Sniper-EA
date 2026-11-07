//+------------------------------------------------------------------+
//| GoldSniper_BTCUSD_Test.mq5                                           |
//| Demo-test variant for BTCUSD and other crypto CFD symbols         |
//| Uses EMA crossover + ATR stop; account currency can be ZAR.      |
//| IMPORTANT: Test on DEMO first. This version has no news filter.  |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "Gold Sniper BTCUSD demo-test variant - EMA/ATR"


//--- Trading and risk inputs
input ulong  MagicNumber       = 6112026;
input double RiskPercent       = 1.0;     // Risk as % of equity
input double MaxRiskMoney      = 35.0;    // Maximum account-currency risk per trade (R35 on a ZAR account)
input double RewardRiskRatio  = 5.0;     // Take profit = stop distance x this ratio
input int    FastEMAPeriod     = 20;
input int    SlowEMAPeriod     = 50;
input int    ATRPeriod         = 14;
input double ATRStopMultiplier = 2.0;
input double MaxSpreadPercent = 0.05;    // Maximum spread as % of BTCUSD mid-price; keep protection enabled
input int    SlippagePoints    = 30;

//--- Indicator handles
int fastMAHandle = INVALID_HANDLE;
int slowMAHandle = INVALID_HANDLE;
int atrHandle    = INVALID_HANDLE;

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
      MaxSpreadPercent <= 0.0)
   {
      Print("Gold Sniper BTC: invalid input settings.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle    = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(fastMAHandle == INVALID_HANDLE ||
      slowMAHandle == INVALID_HANDLE ||
      atrHandle == INVALID_HANDLE)
   {
      Print("Gold Sniper BTC: could not create indicator handles. Error: ", GetLastError());
      return(INIT_FAILED);
   }

   Print("Gold Sniper BTC initialized on ", _Symbol,
         ". Risk is calculated in the account deposit currency.");
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
void OnTick()
{
   if(!IsNewBar())
      return;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

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
   ArrayResize(fast, 3);
   ArrayResize(slow, 3);
   ArrayResize(atr, 3);
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(fastMAHandle, 0, 0, 3, fast) < 3 ||
      CopyBuffer(slowMAHandle, 0, 0, 3, slow) < 3 ||
      CopyBuffer(atrHandle, 0, 0, 3, atr) < 3)
   {
      Print("Gold Sniper BTC: waiting for indicator data.");
      return;
   }

   // Use the two completed candles to avoid acting on a changing candle.
   bool buySignal  = (fast[2] <= slow[2] && fast[1] > slow[1]);
   bool sellSignal = (fast[2] >= slow[2] && fast[1] < slow[1]);

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
