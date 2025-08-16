//+------------------------------------------------------------------+
//|                                                   LondonBreakEA.mq5 |
//|                             Session Breakout with Risk Management |
//+------------------------------------------------------------------+
#property copyright   "You"
#property version     "1.1"
#property strict

// ======= Inputs =======
input string  AllowedSymbols      = "XAUUSD,GBPJPY"; 
input double  RiskPercent         = 1.0;             
input bool    UseATR              = true;
input int     ATRPeriod           = 14;
input double  ATR_SL_Mult         = 1.0;
input double  ATR_TP_Mult         = 2.0;
input double  Range_SL_Mult       = 0.8;             
input double  Range_TP_Mult       = 1.6;             

// Sessions
input int     AsiaStartHour       = 9;  
input int     AsiaEndHour         = 15;  
input int     LondonStartHour     = 8;   
input int     LondonStartMinute   = 30;  

// Trade management
input int     SlippagePoints      = 30;
input double  MaxSpreadPoints     = 35;  
input bool    AllowLong           = true;
input bool    AllowShort          = true;
input double  MinRR               = 1.2; 
input bool    UseBreakeven        = true;
input double  BE_At_RR            = 1.0; 
input bool    UseTrailing         = true;
input int     TrailStartPoints    = 300; 
input int     TrailStepPoints     = 100; 
input bool    UsePartialClose     = true;
input double  PartialClosePct     = 50.0; 
input double  PartialAtRR         = 1.0;  
input long    Magic               = 777001;

// EMA Confirmation
input bool    UseEMAConfirm       = true;
input int     FastEMA             = 20;
input int     SlowEMA             = 50;
input ENUM_TIMEFRAMES EMA_Timeframe = PERIOD_M15;

// ======= Globals =======
double AsiaHigh = 0.0;
double AsiaLow  = 0.0;
int    AsiaDay  = -1;
bool   AsiaBuilt = false;

// ======= Helpers =======
bool SymbolAllowed(const string sym)
{
   string list = AllowedSymbols;
   StringToUpper(list);
   string s = sym; StringToUpper(s);
   return (StringFind(","+list+",", ","+s+",") >= 0);
}

bool InHourRange(datetime t, int hStart, int hEnd)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   int h = dt.hour;
   return (h >= hStart && h < hEnd);
}

bool InAsia(datetime t)
{
   return InHourRange(t, AsiaStartHour, AsiaEndHour);
}

bool AtLondonOpen(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return (dt.hour == LondonStartHour && dt.min == LondonStartMinute);
}

bool NewDay(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return (dt.day != AsiaDay);
}

int PointsFromPrice(double dist)
{
   return (int)MathRound( dist / SymbolInfoDouble(_Symbol, SYMBOL_POINT) );
}

double GetATR(const string sym, ENUM_TIMEFRAMES tf, int period)
{
   double atr[];
   int handle = iATR(sym, tf, period);
   if(handle==INVALID_HANDLE) return 0.0;
   ArraySetAsSeries(atr,true);
   if(CopyBuffer(handle,0,0,3,atr)<1) return 0.0;
   return atr[0];
}

bool SpreadOK()
{
   double spread = (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   return spread <= MaxSpreadPoints || MaxSpreadPoints <= 0;
}

int CountOpenPositions()
{
   int total=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC)==Magic && PositionGetString(POSITION_SYMBOL)==_Symbol)
            total++;
      }
   }
   return total;
}

bool EMAConfirm(bool isBuy)
{
   if(!UseEMAConfirm) return true; // skip if disabled
   double fastEMA = iMA(_Symbol, EMA_Timeframe, FastEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
   double slowEMA = iMA(_Symbol, EMA_Timeframe, SlowEMA, 0, MODE_EMA, PRICE_CLOSE, 0);
   
   if(isBuy) return fastEMA > slowEMA;
   else      return fastEMA < slowEMA;
}

bool PlaceStopOrder(bool isBuy, double entryPrice, double sl, double tp)
{
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_PENDING;
   req.symbol   = _Symbol;
   req.magic    = Magic;
   req.type     = isBuy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   req.price    = entryPrice;
   req.sl       = sl;
   req.tp       = tp;
   req.deviation= SlippagePoints;

   // Sizing by risk
   double stopDist = MathAbs(entryPrice - sl);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * (RiskPercent/100.0);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickVal<=0 || stopDist<=0) return false;
   double valuePerUnit = tickVal / tickSize;
   double qty = riskCash / (stopDist * valuePerUnit);

   // Normalize to lot step & min/max
   double minLot, maxLot, lotStep;
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, minLot);
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, maxLot);
   SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, lotStep);
   qty = MathMax(minLot, MathMin(maxLot, MathFloor(qty/lotStep)*lotStep));
   req.volume = qty;

   return OrderSend(req,res) && res.retcode==10009;
}

// ======= Main Logic =======
void OnTick()
{
   datetime t = TimeCurrent();
   if(NewDay(t))
   {
      AsiaDay = TimeDay(t);
      AsiaHigh = -DBL_MAX;
      AsiaLow  = DBL_MAX;
      AsiaBuilt = false;
   }

   // Build Asia range
   if(InAsia(t))
   {
      double high = iHigh(_Symbol, PERIOD_M1, 0);
      double low  = iLow(_Symbol, PERIOD_M1, 0);
      if(high>AsiaHigh) AsiaHigh = high;
      if(low<AsiaLow)   AsiaLow  = low;
      AsiaBuilt = true;
   }

   // London breakout
   if(AsiaBuilt && AtLondonOpen(t) && SpreadOK() && CountOpenPositions()==0)
   {
      double entryBuy  = AsiaHigh + SymbolInfoDouble(_Symbol,SYMBOL_POINT)*5;  // small offset
      double entrySell = AsiaLow  - SymbolInfoDouble(_Symbol,SYMBOL_POINT)*5;

      double slBuy, tpBuy, slSell, tpSell;
      double atr = UseATR ? GetATR(_Symbol, PERIOD_M15, ATRPeriod) : 0.0;
      double range = AsiaHigh - AsiaLow;

      if(UseATR && atr>0)
      {
         slBuy  = entryBuy - atr*ATR_SL_Mult;
         tpBuy  = entryBuy + atr*ATR_TP_Mult;
         slSell = entrySell + atr*ATR_SL_Mult;
         tpSell = entrySell - atr*ATR_TP_Mult;
      }
      else
      {
         slBuy  = entryBuy - range*Range_SL_Mult;
         tpBuy  = entryBuy + range*Range_TP_Mult;
         slSell = entrySell + range*Range_SL_Mult;
         tpSell = entrySell - range*Range_TP_Mult;
      }

      if(AllowLong && EMAConfirm(true)) PlaceStopOrder(true, entryBuy, slBuy, tpBuy);
      if(AllowShort && EMAConfirm(false)) PlaceStopOrder(false, entrySell, slSell, tpSell);
   }
}
