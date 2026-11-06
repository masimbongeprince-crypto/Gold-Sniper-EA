
#property strict
#property version "1.10"
#property description "Gold Sniper EA - XM MT5 ZAR"

#include <Trade/Trade.mqh>
CTrade trade;

// Risk settings
input double RiskPercent = 2.0;
input double MaxRiskZAR = 35.0;

// Trading settings
input int StopLossPoints = 500;
input int TakeProfitPoints = 2500;
input int FastEMA = 20;
input int SlowEMA = 50;
input int MagicNumber = 6062026;
input int MaxSpreadPoints = 80;
input int SlippagePoints = 30;

int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   string symbolName = _Symbol;
   StringToUpper(symbolName);

   if(StringFind(symbolName, "GOLD") < 0 &&
      StringFind(symbolName, "XAU") < 0)
   {
      Print("Attach Gold Sniper to a GOLD chart.");
      return INIT_FAILED;
   }

   if(AccountInfoString(ACCOUNT_CURRENCY) != "ZAR")
   {
      Print("Account currency must be ZAR.");
      return INIT_FAILED;
   }

   if(RiskPercent <= 0 || MaxRiskZAR <= 0 ||
      StopLossPoints <= 0 || TakeProfitPoints <= 0 ||
      FastEMA <= 0 || SlowEMA <= FastEMA ||
      MaxSpreadPoints <= 0)
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   fastHandle = iMA(_Symbol, PERIOD_M5,
                    FastEMA, 0, MODE_EMA, PRICE_CLOSE);

   slowHandle = iMA(_Symbol, PERIOD_M5,
                    SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE ||
      slowHandle == INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = iTime(_Symbol, PERIOD_M5, 0);

   Print("Gold Sniper v1.10 initialized.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE)
      IndicatorRelease(fastHandle);

   if(slowHandle != INVALID_HANDLE)
      IndicatorRelease(slowHandle);
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
int VolumeDigits(double step)
{
   int digits = 0;

   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   return digits;
}

//+------------------------------------------------------------------+
double CalculateLotSize(ENUM_ORDER_TYPE orderType,
                        double entry,
                        double stopLoss)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney = MathMin(
      balance * RiskPercent / 100.0,
      MaxRiskZAR
   );

   if(riskMoney <= 0)
      return 0;

   double lossOneLot = 0;

   if(!OrderCalcProfit(orderType, _Symbol, 1.0,
                       entry, stopLoss, lossOneLot))
      return 0;

   lossOneLot = MathAbs(lossOneLot);

   if(lossOneLot <= 0)
      return 0;

   double rawVolume = riskMoney / lossOneLot;

   double minLot = SymbolInfoDouble(
      _Symbol, SYMBOL_VOLUME_MIN);

   double maxLot = SymbolInfoDouble(
      _Symbol, SYMBOL_VOLUME_MAX);

   double lotStep = SymbolInfoDouble(
      _Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0 || minLot <= 0)
      return 0;

   double volume = MathFloor(rawVolume / lotStep)
                   * lotStep;

   volume = MathMin(volume, maxLot);

   if(volume < minLot)
   {
      Print("Trade skipped: minimum lot exceeds risk limit.");
      return 0;
   }

   volume = NormalizeDouble(volume, VolumeDigits(lotStep));

   double actualLoss = 0;

   if(!OrderCalcProfit(orderType, _Symbol, volume,
                       entry, stopLoss, actualLoss))
      return 0;

   if(MathAbs(actualLoss) > riskMoney)
      return 0;

   return volume;
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);

   if(currentBar == 0 || currentBar == lastBarTime)
      return;

   lastBarTime = currentBar;

   if(HasOpenPosition())
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(ask <= 0 || bid <= 0 || point <= 0)
      return;

   double spread = (ask - bid) / point;

   if(spread > MaxSpreadPoints)
      return;

   double fast[];
   double slow[];

   ArrayResize(fast, 3);
   ArrayResize(slow, 3);

   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(fastHandle, 0, 0, 3, fast) < 3)
      return;

   if(CopyBuffer(slowHandle, 0, 0, 3, slow) < 3)
      return;

   int stopsLevel = (int)SymbolInfoInteger(
      _Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(StopLossPoints < stopsLevel ||
      TakeProfitPoints < stopsLevel)
      return;

   double slDistance = StopLossPoints * point;
   double tpDistance = TakeProfitPoints * point;

   // BUY signal
   if(fast[1] > slow[1] && fast[2] <= slow[2])
   {
      double sl = NormalizeDouble(
         ask - slDistance, _Digits);

      double tp = NormalizeDouble(
         ask + tpDistance, _Digits);

      double volume = CalculateLotSize(
         ORDER_TYPE_BUY, ask, sl);

      if(volume <= 0)
         return;

      if(!trade.Buy(volume, _Symbol, 0, sl, tp,
                    "Gold Sniper Buy"))
      {
         Print("BUY failed: ",
               trade.ResultRetcodeDescription());
      }
      else
      {
         Print("BUY submitted. Volume: ", volume);
      }
   }

   // SELL signal
   if(fast[1] < slow[1] && fast[2] >= slow[2])
   {
      double sl = NormalizeDouble(
         bid + slDistance, _Digits);

      double tp = NormalizeDouble(
         bid - tpDistance, _Digits);

      double volume = CalculateLotSize(
         ORDER_TYPE_SELL, bid, sl);

      if(volume <= 0)
         return;

      if(!trade.Sell(volume, _Symbol, 0, sl, tp,
                     "Gold Sniper Sell"))
      {
         Print("SELL failed: ",
               trade.ResultRetcodeDescription());
      }
      else
      {
         Print("SELL submitted. Volume: ", volume);
      }
   }
}

#property strict
#property version "1.00"
#property description "Gold Sniper EA - XM MT5"

#include <Trade/Trade.mqh>
CTrade trade;

input double RiskPercent = 2.0;
input double MaxRiskZAR = 35.0;
input int StopLossPoints = 500;
input int TakeProfitPoints = 2500;
input int FastEMA = 20;
input int SlowEMA = 50;
input int MagicNumber = 6062026;
input int MaxSpreadPoints = 80;

int fastHandle, slowHandle;

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   fastHandle = iMA(_Symbol, PERIOD_M5, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, PERIOD_M5, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
      return INIT_FAILED;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);
}

void OnTick()
{
   if(_Symbol != "XAUUSD") return;
   if(PositionSelect(_Symbol)) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if((ask - bid) / point > MaxSpreadPoints) return;

   double fast[3], slow[3];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(fastHandle, 0, 0, 3, fast) < 3) return;
   if(CopyBuffer(slowHandle, 0, 0, 3, slow) < 3) return;

   double riskMoney = MathMin(AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0, MaxRiskZAR);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0) return;

   double slDistance = StopLossPoints * point;
   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return;

   double volume = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / lotStep) * lotStep;
   volume = MathMax(minLot, MathMin(maxLot, volume));

   if(lossPerLot * volume > riskMoney) return;

   if(fast[1] > slow[1] && fast[2] <= slow[2])
   {
      double sl = NormalizeDouble(ask - slDistance, _Digits);
      double tp = NormalizeDouble(ask + TakeProfitPoints * point, _Digits);
      trade.Buy(volume, _Symbol, ask, sl, tp, "Gold Sniper Buy");
   }

   if(fast[1] < slow[1] && fast[2] >= slow[2])
   {
      double sl = NormalizeDouble(bid + slDistance, _Digits);
      double tp = NormalizeDouble(bid - TakeProfitPoints * point, _Digits);
      trade.Sell(volume, _Symbol, bid, sl, tp, "Gold Sniper Sell");
   }
}
