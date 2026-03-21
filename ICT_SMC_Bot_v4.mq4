//+------------------------------------------------------------------+
//|  ICT_SMC_Bot_v4.mq4                                             |
//|  ICT/SMC Strategy for XAUUSD (Gold)                             |
//|  Features: Order Blocks, FVG, Kill Zones, BE, Trailing Stop     |
//|  Fixes: BUY+SELL signals, ATR filter, Gap protection,           |
//|          Pip normalization, MODE_STOPLEVEL validation            |
//+------------------------------------------------------------------+
#property copyright "ICT SMC Bot v4.0"
#property version   "4.00"
#property strict

//--- Input parameters
input double FixedLot             = 0.5;
input double MaxDailyLoss_Pct     = 2.5;
input int    MaxTradesPerDay      = 4;
input int    MaxOpenTrades        = 1;
input int    SL_Pips              = 40;
input int    TP_Pips              = 120;
input bool   UseBE                = true;
input int    BE_Trigger_Pips      = 40;
input int    BE_Buffer_Pips       = 3;
input bool   UseTrail             = true;
input int    Trail_Pips           = 50;
input int    EMA_Fast             = 50;
input int    EMA_Slow             = 200;
input int    OB_Lookback          = 25;
input int    FVG_MinPips          = 8;
input int    OB_TouchPips         = 20;
input int    ConfidenceMin        = 60;
input int    SwingLookback        = 5;
input int    BrokerGMT            = 2;
input int    LondonStart          = 7;
input int    LondonEnd            = 11;
input int    NewYorkStart         = 13;
input int    NewYorkEnd           = 17;
input int    SpreadMax            = 200;
input int    MinTimeBetweenTrades = 30;
input int    MaxConsecutiveLosses = 3;
input int    ATR_Period           = 14;
input double ATR_MaxMultiplier    = 2.0;
input int    GapProtect_Pips      = 15;
input int    MagicNumber          = 202504;
input string TradeComment         = "ICT_v4";

//--- Global variables
datetime g_lastTradeTime   = 0;
int      g_tradesToday     = 0;
datetime g_lastTradeDay    = 0;
int      g_consecLosses    = 0;

//+------------------------------------------------------------------+
//| Pip helper: correct for 4 and 5 decimal brokers                  |
//+------------------------------------------------------------------+
double GetPip()
{
   return (Digits == 5 || Digits == 3) ? Point * 10.0 : Point;
}

//+------------------------------------------------------------------+
//| EMA trend on D1 and H4                                           |
//| Returns  1 = bullish, -1 = bearish, 0 = neutral/no data         |
//+------------------------------------------------------------------+
int GetEMATrend()
{
   double emaFastD1  = iMA(NULL, PERIOD_D1,  EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlowD1  = iMA(NULL, PERIOD_D1,  EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaFastH4  = iMA(NULL, PERIOD_H4,  EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlowH4  = iMA(NULL, PERIOD_H4,  EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);

   if(emaFastD1 <= 0 || emaSlowD1 <= 0 || emaFastH4 <= 0 || emaSlowH4 <= 0)
      return 0;

   bool bullD1 = emaFastD1 > emaSlowD1;
   bool bullH4 = emaFastH4 > emaSlowH4;

   if(bullD1 && bullH4)  return  1;
   if(!bullD1 && !bullH4) return -1;
   return 0;  // conflicting timeframes
}

//+------------------------------------------------------------------+
//| H1 swing structure bias                                          |
//| Returns  1 = HH/HL (bullish), -1 = LH/LL (bearish), 0 = neutral |
//+------------------------------------------------------------------+
int GetSwingBias()
{
   int look = SwingLookback;
   int bars = iBars(NULL, PERIOD_H1);
   if(bars < look * 2 + 2) return 0;

   // Find swing high and low in lookback window
   double swingHigh1 = 0, swingHigh2 = 0;
   double swingLow1  = DBL_MAX, swingLow2 = DBL_MAX;
   int    idxHigh1 = -1, idxHigh2 = -1;
   int    idxLow1  = -1, idxLow2  = -1;

   for(int i = 1; i < look * 2 && i < bars - 1; i++)
   {
      double hi = iHigh(NULL, PERIOD_H1, i);
      double lo = iLow(NULL,  PERIOD_H1, i);

      // Swing high: higher than neighbours on both sides
      if(i >= 1 && i < bars - 1)
      {
         bool isSwingHigh = true;
         bool isSwingLow  = true;
         for(int k = MathMax(1, i - look); k <= MathMin(bars - 2, i + look); k++)
         {
            if(k == i) continue;
            if(iHigh(NULL, PERIOD_H1, k) >= hi) { isSwingHigh = false; break; }
         }
         for(int k = MathMax(1, i - look); k <= MathMin(bars - 2, i + look); k++)
         {
            if(k == i) continue;
            if(iLow(NULL, PERIOD_H1, k) <= lo) { isSwingLow = false; break; }
         }
         if(isSwingHigh)
         {
            if(idxHigh1 < 0) { swingHigh1 = hi; idxHigh1 = i; }
            else if(idxHigh2 < 0) { swingHigh2 = hi; idxHigh2 = i; }
         }
         if(isSwingLow)
         {
            if(idxLow1 < 0) { swingLow1 = lo; idxLow1 = i; }
            else if(idxLow2 < 0) { swingLow2 = lo; idxLow2 = i; }
         }
      }
   }

   // Need at least two swing points to compare
   if(idxHigh1 >= 0 && idxHigh2 >= 0 && idxLow1 >= 0 && idxLow2 >= 0)
   {
      bool hhhl = (swingHigh1 > swingHigh2) && (swingLow1 > swingLow2);
      bool lhll = (swingHigh1 < swingHigh2) && (swingLow1 < swingLow2);
      if(hhhl) return  1;
      if(lhll) return -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Find Order Block on M15                                          |
//| type: 1 = bullish OB (last bearish candle before up move)       |
//|       -1 = bearish OB (last bullish candle before down move)    |
//| Returns true and fills obHigh/obLow if found and price is in OB |
//+------------------------------------------------------------------+
bool FindOrderBlock(int obType, double &obHigh, double &obLow, double &sweepExtreme)
{
   int bars = iBars(NULL, PERIOD_M15);
   if(bars < OB_Lookback + 3) return false;

   double pip = GetPip();
   double touchRange = OB_TouchPips * pip;

   for(int i = 2; i < OB_Lookback && i < bars - 2; i++)
   {
      double curClose = iClose(NULL, PERIOD_M15, i);
      double curOpen  = iOpen(NULL,  PERIOD_M15, i);
      double curHigh  = iHigh(NULL,  PERIOD_M15, i);
      double curLow   = iLow(NULL,   PERIOD_M15, i);
      double prevLow  = iLow(NULL,   PERIOD_M15, i + 1);
      double prevHigh = iHigh(NULL,  PERIOD_M15, i + 1);

      if(obType == 1)  // Looking for bullish OB
      {
         // Bearish candle (close < open) followed by bullish move
         bool isBearish = (curClose < curOpen);
         bool nextBullish = (iClose(NULL, PERIOD_M15, i - 1) > iOpen(NULL, PERIOD_M15, i - 1));
         if(!isBearish || !nextBullish) continue;

         // Price currently touching OB zone from above
         if(Ask >= curLow - touchRange && Ask <= curHigh + touchRange)
         {
            obHigh        = curHigh;
            obLow         = curLow;
            sweepExtreme  = prevLow;  // liquidity below the OB
            return true;
         }
      }
      else if(obType == -1)  // Looking for bearish OB
      {
         // Bullish candle (close > open) followed by bearish move
         bool isBullish  = (curClose > curOpen);
         bool nextBearish = (iClose(NULL, PERIOD_M15, i - 1) < iOpen(NULL, PERIOD_M15, i - 1));
         if(!isBullish || !nextBearish) continue;

         // Price currently touching OB zone from below
         if(Bid <= curHigh + touchRange && Bid >= curLow - touchRange)
         {
            obHigh        = curHigh;
            obLow         = curLow;
            sweepExtreme  = prevHigh;  // liquidity above the OB
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find Fair Value Gap on M15                                       |
//| fvgType: 1 = bullish FVG, -1 = bearish FVG                     |
//+------------------------------------------------------------------+
bool FindFVG(int fvgType)
{
   int bars = iBars(NULL, PERIOD_M15);
   if(bars < OB_Lookback + 3) return false;

   double pip = GetPip();
   double minGap = FVG_MinPips * pip;

   for(int i = 2; i < OB_Lookback && i < bars - 2; i++)
   {
      double highI2  = iHigh(NULL, PERIOD_M15, i + 1);
      double lowI2   = iLow(NULL,  PERIOD_M15, i + 1);
      double highI   = iHigh(NULL, PERIOD_M15, i);
      double lowI    = iLow(NULL,  PERIOD_M15, i);
      double highI1  = iHigh(NULL, PERIOD_M15, i - 1);
      double lowI1   = iLow(NULL,  PERIOD_M15, i - 1);

      if(fvgType == 1)
      {
         // Bullish FVG: gap between high of candle[i+1] and low of candle[i-1]
         double gap = lowI1 - highI2;
         if(gap >= minGap && Ask >= highI2 && Ask <= lowI1)
            return true;
      }
      else if(fvgType == -1)
      {
         // Bearish FVG: gap between low of candle[i+1] and high of candle[i-1]
         double gap = lowI2 - highI1;
         if(gap >= minGap && Bid >= highI1 && Bid <= lowI2)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| ATR filter: avoid entries during excessive volatility            |
//+------------------------------------------------------------------+
bool ATR_OK()
{
   double atr = iATR(NULL, PERIOD_M15, ATR_Period, 1);
   double avgAtr = 0;
   for(int i = 1; i <= ATR_Period; i++)
      avgAtr += iATR(NULL, PERIOD_M15, ATR_Period, i);
   avgAtr /= ATR_Period;

   if(avgAtr <= 0) return true;
   return (atr <= avgAtr * ATR_MaxMultiplier);
}

//+------------------------------------------------------------------+
//| Gap protection: don't enter if current candle already moved too  |
//| much from open (price gapped away from entry zone)              |
//+------------------------------------------------------------------+
bool GapOK(int direction)
{
   double pip   = GetPip();
   double limit = GapProtect_Pips * pip;
   double curOpen = iOpen(NULL, PERIOD_M15, 0);

   if(direction == 1)
   {
      // For BUY: reject if Ask is already much higher than candle open
      return (Ask - curOpen <= limit);
   }
   else
   {
      // For SELL: reject if Bid is already much lower than candle open
      return (curOpen - Bid <= limit);
   }
}

//+------------------------------------------------------------------+
//| Kill Zone check: only trade during London and New York sessions  |
//+------------------------------------------------------------------+
bool InKillZone()
{
   datetime serverTime = TimeCurrent();
   int gmtHour = (int)((serverTime / 3600) % 24);
   // Adjust from broker server time to GMT
   int gmtAdj = gmtHour - BrokerGMT;
   if(gmtAdj < 0)  gmtAdj += 24;
   if(gmtAdj > 23) gmtAdj -= 24;

   bool london  = (gmtAdj >= LondonStart  && gmtAdj < LondonEnd);
   bool newYork = (gmtAdj >= NewYorkStart && gmtAdj < NewYorkEnd);
   return (london || newYork);
}

//+------------------------------------------------------------------+
//| Spread check                                                     |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   return ((int)MarketInfo(Symbol(), MODE_SPREAD) <= SpreadMax);
}

//+------------------------------------------------------------------+
//| Count open trades with our magic number                         |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
            count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count trades opened today                                        |
//+------------------------------------------------------------------+
int CountTradesToday()
{
   int count = 0;
   datetime dayStart = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
            if(OrderOpenTime() >= dayStart)
               count++;
      }
   }
   // Also count open trades opened today
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
            if(OrderOpenTime() >= dayStart)
               count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count consecutive losses (today only to avoid permanent block)  |
//+------------------------------------------------------------------+
int CountConsecLosses()
{
   int consec = 0;
   datetime dayStart = (datetime)(TimeCurrent() - TimeCurrent() % 86400);

   // Walk history from most recent backward
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderCloseTime() < dayStart) break;  // stop at today boundary

      if(OrderProfit() < 0)
         consec++;
      else
         break;  // streak broken
   }
   return consec;
}

//+------------------------------------------------------------------+
//| Daily loss check                                                 |
//+------------------------------------------------------------------+
bool DailyLossOK()
{
   double balance   = AccountBalance();
   double maxLoss   = balance * MaxDailyLoss_Pct / 100.0;
   double todayPnL  = 0;
   datetime dayStart = (datetime)(TimeCurrent() - TimeCurrent() % 86400);

   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderCloseTime() < dayStart) break;
      todayPnL += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return (todayPnL > -maxLoss);
}

//+------------------------------------------------------------------+
//| Manage open trades: Break-Even and Trailing Stop                 |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   double pip      = GetPip();
   double minStop  = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderSymbol() != Symbol()) continue;

      int    type    = OrderType();
      double sl      = OrderStopLoss();
      double entry   = OrderOpenPrice();
      double newSL   = sl;

      if(type == OP_BUY)
      {
         double profit = (Bid - entry) / pip;

         // Break-Even
         if(UseBE && profit >= BE_Trigger_Pips)
         {
            double beSL = entry + BE_Buffer_Pips * pip;
            if(beSL > sl)
               newSL = beSL;
         }

         // Trailing Stop
         if(UseTrail && profit >= Trail_Pips)
         {
            double trailSL = Bid - Trail_Pips * pip;
            if(trailSL > newSL)
               newSL = trailSL;
         }

         // Validate against MODE_STOPLEVEL
         double maxAllowedSL = Bid - minStop;
         if(newSL > maxAllowedSL) newSL = maxAllowedSL;

         if(newSL > sl && newSL > 0)
            OrderModify(OrderTicket(), entry, newSL, OrderTakeProfit(), 0, clrNONE);
      }
      else if(type == OP_SELL)
      {
         double profit = (entry - Ask) / pip;

         // Break-Even
         if(UseBE && profit >= BE_Trigger_Pips)
         {
            double beSL = entry - BE_Buffer_Pips * pip;
            if(sl <= 0 || beSL < sl)
               newSL = beSL;
         }

         // Trailing Stop
         if(UseTrail && profit >= Trail_Pips)
         {
            double trailSL = Ask + Trail_Pips * pip;
            if(sl <= 0 || trailSL < newSL)
               newSL = trailSL;
         }

         // Validate against MODE_STOPLEVEL
         double minAllowedSL = Ask + minStop;
         if(newSL > 0 && newSL < minAllowedSL) newSL = minAllowedSL;

         if(newSL > 0 && (sl <= 0 || newSL < sl))
            OrderModify(OrderTicket(), entry, newSL, OrderTakeProfit(), 0, clrNONE);
      }
   }
}

//+------------------------------------------------------------------+
//| Normalize lot size                                               |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Generate signal and confidence score                             |
//| Returns  1 = BUY, -1 = SELL, 0 = no signal                     |
//+------------------------------------------------------------------+
int GenerateSignal(double &slPrice, double &tpPrice)
{
   double pip      = GetPip();
   int    emaTrend = GetEMATrend();
   int    swingBias = GetSwingBias();

   // Primary trend filter: both EMA and swing must agree
   if(emaTrend == 0 && swingBias == 0) return 0;
   int bias = (emaTrend != 0) ? emaTrend : swingBias;
   if(emaTrend != 0 && swingBias != 0 && emaTrend != swingBias) return 0;

   // Score-based confluence
   int score = 0;

   // EMA alignment
   if(emaTrend != 0) score += 20;
   // Swing structure
   if(swingBias != 0) score += 15;

   // Kill Zone
   if(InKillZone()) score += 15;

   double obHigh = 0, obLow = 0, sweepExtreme = 0;
   bool   obFound  = FindOrderBlock(bias, obHigh, obLow, sweepExtreme);
   bool   fvgFound = FindFVG(bias);

   if(obFound)  score += 20;
   if(fvgFound) score += 15;

   // Require minimum confluence
   if(score < ConfidenceMin) return 0;

   // ATR and Gap checks
   if(!ATR_OK())       return 0;
   if(!GapOK(bias))    return 0;

   // Calculate SL and TP
   double minStop = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   if(bias == 1)  // BUY
   {
      double slBase = obFound ? obLow : (Ask - SL_Pips * pip);
      double slDist = Ask - slBase;

      // Reject if SL distance exceeds maximum allowed
      if(slDist > SL_Pips * pip) slDist = SL_Pips * pip;
      slBase = Ask - slDist;

      if(slDist < minStop) slBase = Ask - minStop;
      slPrice = NormalizeDouble(slBase, Digits);
      tpPrice = NormalizeDouble(Ask + TP_Pips * pip, Digits);
   }
   else  // SELL
   {
      double slBase = obFound ? obHigh : (Bid + SL_Pips * pip);
      double slDist = slBase - Bid;

      // Reject if SL distance exceeds maximum allowed
      if(slDist > SL_Pips * pip) slDist = SL_Pips * pip;
      slBase = Bid + slDist;

      if(slDist < minStop) slBase = Bid + minStop;
      slPrice = NormalizeDouble(slBase, Digits);
      tpPrice = NormalizeDouble(Bid - TP_Pips * pip, Digits);
   }

   return bias;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("ICT_SMC_Bot_v4 initialized. Magic=", MagicNumber,
         " Symbol=", Symbol(), " Digits=", Digits,
         " Pip=", GetPip());
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manage existing trades first
   ManageOpenTrades();

   // --- Pre-entry filters ---
   if(!SpreadOK()) return;
   if(!DailyLossOK()) return;
   if(CountOpenTrades() >= MaxOpenTrades) return;
   if(CountTradesToday() >= MaxTradesPerDay) return;
   if(CountConsecLosses() >= MaxConsecutiveLosses) return;

   // Minimum time between trades
   if(TimeCurrent() - g_lastTradeTime < MinTimeBetweenTrades * 60) return;

   // Only trade on new M15 bar open to avoid multiple signals same candle
   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(NULL, PERIOD_M15, 0);
   if(curBarTime == lastBarTime) return;
   lastBarTime = curBarTime;

   // Generate signal
   double slPrice = 0, tpPrice = 0;
   int signal = GenerateSignal(slPrice, tpPrice);
   if(signal == 0) return;

   // Validate SL
   if(slPrice <= 0) return;

   double lot = NormalizeLot(FixedLot);

   int ticket = -1;
   if(signal == 1)
   {
      ticket = OrderSend(Symbol(), OP_BUY, lot, Ask, 3,
                         slPrice, tpPrice, TradeComment, MagicNumber, 0, clrBlue);
   }
   else if(signal == -1)
   {
      ticket = OrderSend(Symbol(), OP_SELL, lot, Bid, 3,
                         slPrice, tpPrice, TradeComment, MagicNumber, 0, clrRed);
   }

   if(ticket > 0)
   {
      g_lastTradeTime = TimeCurrent();
      Print("Trade opened: ticket=", ticket, " type=", (signal == 1 ? "BUY" : "SELL"),
            " SL=", slPrice, " TP=", tpPrice, " Lot=", lot);
   }
   else
   {
      Print("OrderSend failed: error=", GetLastError(),
            " signal=", signal, " SL=", slPrice, " TP=", tpPrice);
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("ICT_SMC_Bot_v4 deinitialized. Reason=", reason);
}
//+------------------------------------------------------------------+
