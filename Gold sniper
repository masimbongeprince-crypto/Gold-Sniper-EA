
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
