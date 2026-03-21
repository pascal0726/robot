//+------------------------------------------------------------------+
//|  ICT_SMC_Bot_v4.mq4                                             |
//+------------------------------------------------------------------+
#property copyright "ICT SMC Bot v4.0"
#property version   "4.00"
#property strict

// --- Gestion du risque ---
input double FixedLot             = 0.5;
input double MaxDailyLoss_Pct     = 2.5;
input int    MaxTradesPerDay      = 4;
input int    MaxOpenTrades        = 1;
// --- SL / TP en pips ---
input int    SL_Pips              = 40;
input int    TP_Pips              = 120;
// --- Break-Even ---
input bool   UseBE                = true;
input int    BE_Trigger_Pips      = 40;
input int    BE_Buffer_Pips       = 3;
// --- Trailing Stop ---
input bool   UseTrail             = true;
input int    Trail_Pips           = 50;
// --- Filtres tendance EMA ---
input int    EMA_Fast             = 50;
input int    EMA_Slow             = 200;
// --- Signal ICT/SMC ---
input int    OB_Lookback          = 50;   // FIX: 25->50 (couvre ~12h en M15)
input int    FVG_MinPips          = 5;    // FIX: 8->5 (plus de FVGs detectes)
input int    OB_TouchPips         = 30;   // FIX: 20->30 (Gold bouge vite)
input int    ConfidenceMin        = 60;
input int    SwingLookback        = 5;
// --- Sessions GMT ---
input int    BrokerGMT            = 2;
input int    LondonStart          = 7;
input int    LondonEnd            = 11;
input int    NewYorkStart         = 13;
input int    NewYorkEnd           = 17;
// --- Filtres ---
input int    SpreadMax            = 200;
input int    MinTimeBetweenTrades = 30;
input int    MaxConsecutiveLosses = 3;
input int    ATR_Period           = 14;
input double ATR_MaxMultiplier    = 2.0;
input int    GapProtect_Pips      = 15;
input int    MagicNumber          = 202504;
input string TradeComment         = "ICT_v4";

// --- Globaux ---
double   g_DailyStartBalance = 0;
int      g_TradesToday       = 0;
datetime g_LastDayReset      = 0;
datetime g_LastBarTime       = 0;
datetime g_LastTradeTime     = 0;
int      g_ConsecutiveLosses = 0;
int      g_LastClosedTicket  = -1;
string   g_Debug             = "";

struct Signal { string direction; double entry, sl, tp; int confidence; };

double GetPip() { return (Digits == 5 || Digits == 3) ? Point * 10.0 : Point; }

//+------------------------------------------------------------------+
int OnInit()
{
   g_DailyStartBalance = AccountBalance();
   g_LastDayReset      = TimeCurrent();
   g_LastTradeTime     = 0;
   g_ConsecutiveLosses = 0;
   g_LastClosedTicket  = -1;
   Print("=== ICT/SMC Bot v4.0 demarre ===");
   Print("BrokerGMT: GMT+", BrokerGMT,
         " | London: ", LondonStart, "-", LondonEnd, "h GMT",
         " | NY: ", NewYorkStart, "-", NewYorkEnd, "h GMT");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) { Print("=== Bot v4.0 arrete. Raison: ", r); }

//+------------------------------------------------------------------+
void OnTick()
{
   datetime curBar = iTime(Symbol(), PERIOD_M15, 0);
   if(curBar == g_LastBarTime) { ManageOpenTrades(); UpdateConsecutiveLosses(); return; }
   g_LastBarTime = curBar;

   ResetDailyCounters();
   ManageOpenTrades();
   UpdateConsecutiveLosses();

   Signal sig;
   GenerateSignal(sig);

   bool inKZ      = IsInKillZone();
   bool spreadOK  = SpreadOK();
   bool atrOK     = ATR_OK();
   bool gapOK     = GapOK(sig.direction);
   int  minsSince = (g_LastTradeTime > 0) ? (int)((TimeCurrent()-g_LastTradeTime)/60) : 9999;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int gmtH = (dt.hour - BrokerGMT + 24) % 24;

   Comment(
      "=== ICT/SMC Bot v4.0 ===\n",
      "Broker: ", dt.hour, "h", dt.min, " | GMT: ", gmtH, "h\n",
      "D1 EMA : ", GetEMATrend(PERIOD_D1), "\n",
      "H4 EMA : ", GetEMATrend(PERIOD_H4), "\n",
      "H1 Swing: ", GetSwingBias(PERIOD_H1), "\n",
      "KZ: ", (inKZ?"OUI":"NON"),
      " | Spread: ", (int)MarketInfo(Symbol(),MODE_SPREAD), "/", SpreadMax,
      " | ATR: ", (atrOK?"OK":"HAUT"),
      " | Gap: ", (gapOK?"OK":"TROP GRAND"), "\n",
      "Trades: ", g_TradesToday, "/", MaxTradesPerDay,
      " | Perte jour: ", DoubleToStr(GetDailyLossPct(),2), "%\n",
      "Pertes cons: ", g_ConsecutiveLosses, "/", MaxConsecutiveLosses,
      " | Attente: ", minsSince, "/", MinTimeBetweenTrades, "min\n",
      "--- Signal ---\n",
      g_Debug,
      "Dir: ", sig.direction, " | Score: ", sig.confidence, "%\n"
   );

   if(!CanTrade() || !inKZ || !spreadOK || !atrOK || !gapOK) return;
   if(sig.direction=="NONE" || sig.confidence<ConfidenceMin)  return;
   if(CountOpenTrades() >= MaxOpenTrades)                      return;
   if(minsSince < MinTimeBetweenTrades)                        return;

   OpenTrade(sig, FixedLot);
}

// ====================== ATR FILTER ======================
bool ATR_OK()
{
   double atrCur = iATR(Symbol(), PERIOD_M15, ATR_Period, 1); // bar 1 = derniere bougie fermee
   double atrAvg = 0;
   for(int i=2; i<=21; i++) atrAvg += iATR(Symbol(), PERIOD_M15, ATR_Period, i);
   atrAvg /= 20.0;
   if(atrAvg <= 0) return true;
   return (atrCur <= atrAvg * ATR_MaxMultiplier);
}

// ====================== GAP PROTECTION ======================
// FIX: prend la direction en parametre pour comparer Ask ou Bid
bool GapOK(string direction)
{
   double pip  = GetPip();
   double open = iOpen(Symbol(), PERIOD_M15, 0);
   double move;
   if(direction == "BUY")
      move = Ask - open;          // pour BUY, mouvement haussier depuis open
   else if(direction == "SELL")
      move = open - Bid;          // pour SELL, mouvement baissier depuis open
   else
      move = MathAbs(Ask - open); // pas encore de direction: check general
   if(move < 0) move = 0;
   return (move <= GapProtect_Pips * pip);
}

// ====================== TENDANCE ======================
string GetEMATrend(int tf)
{
   double fast  = iMA(Symbol(), tf, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slow  = iMA(Symbol(), tf, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double price = iClose(Symbol(), tf, 1);
   // FIX: verification donnees disponibles
   if(fast <= 0 || slow <= 0) return "NEUTRE";
   if(fast > slow && price > fast) return "BUY";
   if(fast < slow && price < fast) return "SELL";
   if(fast > slow)                 return "BUY_FAIBLE";
   if(fast < slow)                 return "SELL_FAIBLE";
   return "NEUTRE";
}

string GetSwingBias(int tf)
{
   double highs[5], lows[5];
   int nh = 0, nl = 0;
   int totalBars = iBars(Symbol(), tf);
   for(int i = SwingLookback+1; i < 100 && (nh<3||nl<3); i++)
   {
      if(i + SwingLookback >= totalBars) break;
      double h = iHigh(Symbol(),tf,i);
      bool isH = true;
      for(int j=1;j<=SwingLookback;j++)
         if(iHigh(Symbol(),tf,i-j)>=h||iHigh(Symbol(),tf,i+j)>=h){isH=false;break;}
      if(isH && nh<5) highs[nh++]=h;

      double l = iLow(Symbol(),tf,i);
      bool isL = true;
      for(int j=1;j<=SwingLookback;j++)
         if(iLow(Symbol(),tf,i-j)<=l||iLow(Symbol(),tf,i+j)<=l){isL=false;break;}
      if(isL && nl<5) lows[nl++]=l;
   }
   if(nh<2||nl<2) return "NEUTRE";
   if(highs[0]>highs[1]&&lows[0]>lows[1]) return "BUY";
   if(highs[0]<highs[1]&&lows[0]<lows[1]) return "SELL";
   return "NEUTRE";
}

string TrendBase(string t)
{
   if(StringFind(t,"BUY")>=0)  return "BUY";
   if(StringFind(t,"SELL")>=0) return "SELL";
   return "NEUTRE";
}

// ====================== SIGNAL (BUY + SELL) ======================
void GenerateSignal(Signal &sig)
{
   sig.direction="NONE"; sig.confidence=0; g_Debug="";

   // FIX: verification que les donnees EMA sont chargees avant tout
   double emaTestD1 = iMA(Symbol(), PERIOD_D1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaTestH4 = iMA(Symbol(), PERIOD_H4, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   if(emaTestD1 <= 0 || emaTestH4 <= 0)
   {
      g_Debug += "-> STOP: Donnees EMA manquantes\n";
      g_Debug += "   Ouvre les charts D1 et H4 et charge l historique!\n";
      return;
   }

   string d1T = GetEMATrend(PERIOD_D1);
   string d1B = TrendBase(d1T);
   g_Debug += "D1: " + d1T + "\n";
   if(d1B=="NEUTRE") { g_Debug+="-> STOP: D1 neutre\n"; return; }
   sig.confidence += (d1T==d1B) ? 35 : 20;

   string h4T = GetEMATrend(PERIOD_H4);
   string h4B = TrendBase(h4T);
   g_Debug += "H4: " + h4T + "\n";
   if(h4B!="NEUTRE" && h4B!=d1B) { g_Debug+="-> STOP: H4 oppose D1\n"; return; }
   sig.confidence += (h4B==d1B) ? 25 : 10;

   string h1B = GetSwingBias(PERIOD_H1);
   g_Debug += "H1: " + h1B + "\n";
   if(h1B!="NEUTRE" && h1B!=d1B) { g_Debug+="-> STOP: H1 oppose D1\n"; return; }
   if(h1B==d1B) sig.confidence += 15;

   string bias = d1B;

   double obTop=0, obBot=0;
   bool obFound = FindOrderBlock(obTop, obBot, bias, PERIOD_M15);
   g_Debug += "OB: " + (obFound?"OUI":"NON") + "\n";
   if(!obFound) { g_Debug+="-> STOP: Pas d OB\n"; return; }
   sig.confidence += 20;

   double fvgT=0, fvgB=0;
   if(FindFVG(fvgT,fvgB,bias,PERIOD_M15)) { sig.confidence+=10; g_Debug+="FVG: OUI\n"; }

   g_Debug += "Score: " + IntegerToString(sig.confidence) + "%\n";
   if(sig.confidence < ConfidenceMin) { g_Debug+="-> STOP: Score insuffisant\n"; return; }

   double pip = GetPip();
   double slD = SL_Pips * pip;
   double tpD = TP_Pips * pip;
   double minStop = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   if(bias=="BUY")
   {
      sig.entry = Ask;
      double slBase = (obBot > 0) ? obBot - pip : sig.entry - slD;
      // Si SL trop loin (> SL_Pips), utilise SL fixe
      if(sig.entry - slBase > slD) slBase = sig.entry - slD;
      // Valide contre MODE_STOPLEVEL
      if(sig.entry - slBase < minStop) slBase = sig.entry - minStop;
      sig.sl = slBase;
      sig.tp = sig.entry + tpD;
   }
   else
   {
      sig.entry = Bid;
      double slBase = (obTop > 0) ? obTop + pip : sig.entry + slD;
      // Si SL trop loin (> SL_Pips), utilise SL fixe
      if(slBase - sig.entry > slD) slBase = sig.entry + slD;
      // Valide contre MODE_STOPLEVEL
      if(slBase - sig.entry < minStop) slBase = sig.entry + minStop;
      sig.sl = slBase;
      sig.tp = sig.entry - tpD;
   }

   sig.direction = bias;
}

//+------------------------------------------------------------------+
// FIX PRINCIPAL: mitigation basee sur les CLOTURES, pas les meches
// Un OB est mitigue seulement quand une bougie CLOTURE au-dela
//+------------------------------------------------------------------+
bool FindOrderBlock(double &obTop, double &obBot, string bias, int tf)
{
   double pip   = GetPip();
   double tol   = OB_TouchPips * pip;
   double price = (bias=="BUY") ? Ask : Bid;

   for(int i=2; i<OB_Lookback; i++)
   {
      double o=iOpen(Symbol(),tf,i),  c=iClose(Symbol(),tf,i);
      double h=iHigh(Symbol(),tf,i),  l=iLow(Symbol(),tf,i);

      if(bias=="BUY" && c<o) // bougie baissiere = OB haussier potentiel
      {
         // Confirmation: la bougie qui suit (plus recente) est haussiere
         bool conf = (iClose(Symbol(),tf,i-1) > iOpen(Symbol(),tf,i-1));
         if(!conf) continue;

         // FIX: mitigation = une cloture SOUS le bas de l'OB (pas une simple meche)
         bool mit = false;
         for(int m=1; m<i; m++)
            if(iClose(Symbol(),tf,m) < l) { mit=true; break; }
         if(mit) continue;

         // Prix dans la zone OB (tolerance de OB_TouchPips)
         if(price >= l-tol && price <= h+tol)
         {
            obTop=h; obBot=l; return true;
         }
      }

      if(bias=="SELL" && c>o) // bougie haussiere = OB baissier potentiel
      {
         // Confirmation: la bougie qui suit (plus recente) est baissiere
         bool conf = (iClose(Symbol(),tf,i-1) < iOpen(Symbol(),tf,i-1));
         if(!conf) continue;

         // FIX: mitigation = une cloture AU-DESSUS du haut de l'OB
         bool mit = false;
         for(int m=1; m<i; m++)
            if(iClose(Symbol(),tf,m) > h) { mit=true; break; }
         if(mit) continue;

         // Prix dans la zone OB (tolerance de OB_TouchPips)
         if(price >= l-tol && price <= h+tol)
         {
            obTop=h; obBot=l; return true;
         }
      }
   }
   return false;
}

bool FindFVG(double &top, double &bot, string bias, int tf)
{
   double minGap = FVG_MinPips * GetPip();
   for(int i=2; i<30; i++)
   {
      double hi1=iHigh(Symbol(),tf,i+1), lo1=iLow(Symbol(),tf,i+1);
      double hi3=iHigh(Symbol(),tf,i-1), lo3=iLow(Symbol(),tf,i-1);
      if(bias=="BUY"  && lo3>hi1 && (lo3-hi1)>=minGap) { top=lo3; bot=hi1; return true; }
      if(bias=="SELL" && hi3<lo1 && (lo1-hi3)>=minGap)  { top=lo1; bot=hi3; return true; }
   }
   return false;
}

// ====================== GESTION TRADES ======================
void ManageOpenTrades()
{
   double pip       = GetPip();
   double beTrig    = BE_Trigger_Pips * pip;
   double beBuf     = BE_Buffer_Pips  * pip;
   double trailDist = Trail_Pips      * pip;
   double minStop   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber||OrderSymbol()!=Symbol()) continue;

      int    type  = OrderType();
      double op    = OrderOpenPrice();
      double curSL = OrderStopLoss();
      double curTP = OrderTakeProfit();
      double newSL = curSL;

      if(type==OP_BUY)
      {
         double profit = Bid - op;
         if(UseBE && profit>=beTrig && curSL<op)
            newSL = op + beBuf;
         if(UseTrail && (!UseBE || curSL>=op)) {
            double t = Bid - trailDist;
            if(t > newSL + pip) newSL = t;
         }
         double maxAllowed = Bid - minStop;
         if(newSL > maxAllowed) newSL = maxAllowed;
         if(newSL > curSL + pip)
            if(!OrderModify(OrderTicket(),op,NormalizeDouble(newSL,Digits),curTP,0,clrYellow))
               Print("Modify BUY err:",GetLastError());
      }
      else if(type==OP_SELL)
      {
         double profit = op - Ask;
         if(UseBE && profit>=beTrig && curSL>op)
            newSL = op - beBuf;
         if(UseTrail && (!UseBE || curSL<=op)) {
            double t = Ask + trailDist;
            if(curSL<=0 || t < newSL - pip) newSL = t;
         }
         double minAllowed = Ask + minStop;
         if(curSL<=0 || newSL < minAllowed) newSL = minAllowed;
         if(curSL<=0 || newSL < curSL - pip)
            if(!OrderModify(OrderTicket(),op,NormalizeDouble(newSL,Digits),curTP,0,clrYellow))
               Print("Modify SELL err:",GetLastError());
      }
   }
}

void OpenTrade(Signal &sig, double lot)
{
   double step   = MarketInfo(Symbol(),MODE_LOTSTEP);
   double minLot = MarketInfo(Symbol(),MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(),MODE_MAXLOT);
   lot = MathMax(MathMin(MathFloor(lot/step)*step, maxLot), minLot);

   int    cmd = (sig.direction=="BUY") ? OP_BUY : OP_SELL;
   double pr  = (sig.direction=="BUY") ? Ask    : Bid;

   int ticket = OrderSend(Symbol(), cmd, lot, pr, 10,
      NormalizeDouble(sig.sl,Digits), NormalizeDouble(sig.tp,Digits),
      TradeComment+"_"+sig.direction, MagicNumber, 0,
      (sig.direction=="BUY")?clrLime:clrRed);

   if(ticket < 0)
      Print("ERREUR OrderSend:", GetLastError(), " | ", sig.direction,
            " SL:", NormalizeDouble(sig.sl,Digits),
            " TP:", NormalizeDouble(sig.tp,Digits));
   else {
      g_TradesToday++;
      g_LastTradeTime = TimeCurrent();
      Print("TRADE #",ticket," | ",sig.direction," | Lot:",lot,
            " | Entry:",pr,
            " | SL:",NormalizeDouble(sig.sl,Digits),
            " | TP:",NormalizeDouble(sig.tp,Digits),
            " | Score:",sig.confidence,"%");
   }
}

// ====================== UTILITAIRES ======================
void ResetDailyCounters()
{
   MqlDateTime n,l;
   TimeToStruct(TimeCurrent(),n);
   TimeToStruct(g_LastDayReset,l);
   if(n.day != l.day) {
      g_DailyStartBalance = AccountBalance();
      g_TradesToday       = 0;
      g_ConsecutiveLosses = 0;
      g_LastDayReset      = TimeCurrent();
      Print("Nouveau jour - Balance:", g_DailyStartBalance);
   }
}

bool CanTrade()
{
   if(GetDailyLossPct() >= MaxDailyLoss_Pct)      { g_Debug+="STOP: Perte jour\n"; return false; }
   if(g_TradesToday >= MaxTradesPerDay)             return false;
   if(g_ConsecutiveLosses >= MaxConsecutiveLosses) { g_Debug+="PAUSE: pertes cons\n"; return false; }
   return true;
}

double GetDailyLossPct()
{
   if(g_DailyStartBalance <= 0) return 0;
   return ((g_DailyStartBalance - (AccountBalance()+AccountProfit())) / g_DailyStartBalance) * 100.0;
}

bool IsInKillZone()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int gmtH = (dt.hour - BrokerGMT + 24) % 24;
   return (gmtH>=LondonStart && gmtH<LondonEnd) ||
          (gmtH>=NewYorkStart && gmtH<NewYorkEnd);
}

bool SpreadOK() { return MarketInfo(Symbol(),MODE_SPREAD) <= SpreadMax; }

int CountOpenTrades()
{
   int c=0;
   for(int i=0;i<OrdersTotal();i++)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) &&
         OrderMagicNumber()==MagicNumber && OrderSymbol()==Symbol()) c++;
   return c;
}

void UpdateConsecutiveLosses()
{
   static int lastH = -1;
   int hist = OrdersHistoryTotal();
   if(hist == lastH) return;
   lastH = hist;

   // FIX: ne regarde que les trades du jour pour eviter le blocage permanent
   datetime dayStart = (datetime)(TimeCurrent() - TimeCurrent() % 86400);

   for(int i=hist-1; i>=0; i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderMagicNumber()!=MagicNumber || OrderSymbol()!=Symbol()) continue;
      if(OrderCloseTime() < dayStart) break; // stop au debut du jour
      if(OrderTicket() == g_LastClosedTicket) break;

      g_LastClosedTicket = OrderTicket();
      double res = OrderProfit() + OrderSwap() + OrderCommission();
      g_ConsecutiveLosses = (res < 0) ? g_ConsecutiveLosses+1 : 0;
      break;
   }
}
//+------------------------------------------------------------------+
