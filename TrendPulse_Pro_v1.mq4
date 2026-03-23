//+------------------------------------------------------------------+
//|  TrendPulse_Pro_v1.mq4                                          |
//|  Strategie : Trend + RSI Pullback + MACD + Multi-TF Confluence  |
//|                                                                  |
//|  LOGIQUE :                                                       |
//|   D1  -> Biais de marche (EMA200 direction)                     |
//|   H4  -> Tendance principale (EMA50/200 alignement)             |
//|   H1  -> Structure (EMA21/50 alignement + swing)                |
//|   M15 -> Entree precise (RSI pullback + MACD + EMA21)           |
//|                                                                  |
//|  GESTION RISQUE :                                               |
//|   - Lot dynamique (% risque fixe par trade)                     |
//|   - SL : ATR x 1.5 (dynamique, adapte a la volatilite)         |
//|   - TP1 : 1.5R -> ferme 50%, SL au BE                          |
//|   - TP2 : Trail restant 50% (Chandelier Exit ATR x 2.5)        |
//|                                                                  |
//|  PAS DE GRID - PAS DE MARTINGALE                                |
//+------------------------------------------------------------------+
#property copyright "TrendPulse Pro v1.0"
#property version   "1.00"
#property strict

//=== LOTS =========================================================
input bool   UseFixedLot        = false;  // true = lot fixe | false = lot dynamique (% risque)
input double FixedLot           = 0.10;   // Lot fixe si UseFixedLot = true

//=== GESTION DU RISQUE =============================================
input double RiskPercent         = 1.0;    // % du capital risque par trade (recommande 1-2%)
input double MaxDailyLoss_Pct   = 3.0;    // Perte max journaliere en % avant arret
input double MaxDailyProfit_Pct = 6.0;    // Objectif profit journalier (arret quand atteint)
input int    MaxTradesPerDay    = 3;       // Trades max par jour
input int    MaxOpenTrades      = 1;       // 1 seul trade a la fois (discipline)
input int    MaxConsecLosses    = 4;       // Pause si N pertes consecutives

//=== SL / TP ======================================================
input bool   UseFixedSLTP       = false;  // true = SL/TP fixes en pips | false = ATR dynamique
input int    FixedSL_Pips       = 150;    // SL fixe en pips (si UseFixedSLTP=true)
input int    FixedTP_Pips       = 300;    // TP fixe en pips (si UseFixedSLTP=true)
input double ATR_SL_Mult        = 1.5;    // SL = ATR x ce multiplicateur (si UseFixedSLTP=false)
input double ATR_TP1_Mult       = 2.2;    // TP1 = ATR x ce multiplicateur (si UseFixedSLTP=false)
input double ATR_Trail_Mult     = 2.5;    // Trail TP2 = Chandelier Exit (ATR x mult)
input int    ATR_Period         = 14;      // Periode ATR

//=== BREAK-EVEN & PARTIAL CLOSE ===================================
// Partial close : automatiquement actif si UseFixedLot=false (lot dynamique)
input bool   UseBE              = true;    // Activer break-even apres TP1
input int    BE_Buffer_Pips     = 3;       // Tampon BE (pips au dessus/dessous entree)

//=== FILTRES TENDANCE ==============================================
input int    EMA_Fast           = 21;      // EMA rapide (M15/H1 structure)
input int    EMA_Mid            = 50;      // EMA milieu (H4 tendance)
input int    EMA_Slow           = 200;     // EMA lente (D1 biais)

//=== FILTRE PENTE D1 POUR SHORTS =================================
input double ShortSlopeMultiplier = 3.0;  // Multiplicateur pente D1 pour SHORT (plus grand = plus de SHORTs)

//=== FILTRES MACD ================================================
input int    MACD_Fast          = 12;      // MACD rapide
input int    MACD_Slow          = 26;      // MACD lent
input int    MACD_Signal        = 9;       // MACD signal

//=== SESSIONS (heures France / Paris) ============================
input bool   UseSessionFilter   = false;   // Activer filtre sessions
input int    BrokerGMT          = 2;       // GMT du broker
input int    ParisGMT           = 2;       // GMT Paris (ete=2, hiver=1)
input int    LondonOpen         = 7;       // Ouverture London (heure Paris)
input int    LondonClose        = 12;      // Fermeture London (heure Paris)
input int    NYOpen             = 13;      // Ouverture New York (heure Paris)
input int    NYClose            = 17;      // Fermeture New York (heure Paris)

//=== FILTRES MARCHE ===============================================
input int    SpreadMax          = 100;     // Spread max en points (100=1pip EURUSD, augmente pour XAUUSD)
input double ATR_VolatMax       = 3.0;     // Bloque si ATR > N x moyenne (news/spike)
input int    CooldownMins       = 30;      // Pause en minutes apres une perte
input int    GapProtectPips     = 500;     // Bloque si gap > N pips (week-end gap)

//=== MAGIC & COMMENTAIRE ==========================================
input int    MagicNumber        = 303030;
input string TradeComment       = "TrendPulse";

//=== GLOBAUX ======================================================
double   g_Balance0      = 0;    // Balance debut journee
int      g_TradesToday   = 0;    // Trades ouverts aujourd'hui
int      g_ConsecLosses  = 0;    // Pertes consecutives
datetime g_LastDayReset  = 0;    // Derniere reinit journaliere
datetime g_LastBarTime   = 0;    // Derniere bougie M15 traitee
datetime g_LastTradeTime = 0;    // Heure du dernier trade
int      g_LastTicket    = -1;   // Dernier ticket histoire
bool     g_PartialDone   = false;// Partial close effectue sur trade courant
int      g_OpenTicket    = -1;   // Ticket du trade ouvert

//+------------------------------------------------------------------+
//| INIT                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   g_Balance0     = AccountBalance();
   g_LastDayReset = TimeCurrent();
   g_LastTradeTime= 0;
   g_ConsecLosses = 0;
   g_LastTicket   = -1;
   g_OpenTicket   = -1;
   g_PartialDone  = false;

   Print("=== TrendPulse Pro v1.0 demarre ===");
   Print("Risque/trade:", RiskPercent, "% | ATR_SL x", ATR_SL_Mult,
         " | TP1 x", ATR_TP1_Mult, " | Trail x", ATR_Trail_Mult);
   Print("Session filtre:", UseSessionFilter, " | SpreadMax:", SpreadMax,
         " | MaxDailyLoss:", MaxDailyLoss_Pct, "%");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) { Print("=== TrendPulse Pro v1.0 arrete. Code:", r); }

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gestion des trades ouverts a chaque tick
   ManageTrades();
   UpdateHistory();

   // Analyse signal uniquement sur nouvelle bougie M15
   datetime barNow = iTime(Symbol(), PERIOD_M15, 0);
   if(barNow == g_LastBarTime) return;
   g_LastBarTime = barNow;

   ResetDaily();

   // Affichage dashboard
   ShowDashboard();

   // --- DIAGNOSTIC : etat complet a chaque bougie M15 ---
   Print("=BAR= ", TimeToStr(barNow,TIME_DATE|TIME_MINUTES),
         " | Bal:", DoubleToStr(AccountBalance(),2),
         " | g_Bal0:", DoubleToStr(g_Balance0,2),
         " | TradesToday:", g_TradesToday,
         " | ConsecLoss:", g_ConsecLosses,
         " | Spread:", (int)MarketInfo(Symbol(),MODE_SPREAD));

   // Conditions globales
   if(!CanTrade())
   {
      double dd = GetDailyDrawdown();
      double dp = (g_Balance0 > 0) ? ((AccountEquity()-g_Balance0)/g_Balance0*100.0) : 0;
      Print("CANTRADE FALSE | DD:", DoubleToStr(dd,2), "% | DProfit:", DoubleToStr(dp,2),
            "% | TradesToday:", g_TradesToday, "/", MaxTradesPerDay,
            " | ConsecLoss:", g_ConsecLosses, "/", MaxConsecLosses);
      return;
   }
   if(!FilterOK())   return;
   if(CountTrades() >= MaxOpenTrades) return;

   int minsSince = (g_LastTradeTime > 0)
                   ? (int)((TimeCurrent() - g_LastTradeTime) / 60)
                   : 9999;
   int cooldown = (g_ConsecLosses > 0) ? CooldownMins * g_ConsecLosses : 0;
   if(minsSince < cooldown)
   {
      Print("COOLDOWN: ", minsSince, "min < ", cooldown, "min requis");
      return;
   }

   // Calcul signal
   int signal = GetSignal();
   if(signal == 0) return;

   // Calcul SL/TP
   double pip  = GetPip();
   double atr  = iATR(Symbol(), PERIOD_M15, ATR_Period, 1);

   double slDist, tp1Dist;
   if(UseFixedSLTP)
   {
      slDist  = FixedSL_Pips  * pip;
      tp1Dist = FixedTP_Pips  * pip;
   }
   else
   {
      slDist  = atr * ATR_SL_Mult;
      tp1Dist = atr * ATR_TP1_Mult;
   }

   double entry, sl, tp1;
   if(signal == 1) // BUY
   {
      entry = Ask;
      sl    = entry - slDist;
      tp1   = entry + tp1Dist;
   }
   else // SELL
   {
      entry = Bid;
      sl    = entry + slDist;
      tp1   = entry - tp1Dist;
   }

   // Verif stop level minimum broker
   double minStop = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(MathAbs(entry - sl)  < minStop) return;
   if(MathAbs(entry - tp1) < minStop) return;

   // Calcul lot
   double lot;
   if(UseFixedLot)
   {
      lot = FixedLot;
      double minLot = MarketInfo(Symbol(), MODE_MINLOT);
      double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
      double lotStep= MarketInfo(Symbol(), MODE_LOTSTEP);
      lot = NormalizeDouble(MathRound(lot / lotStep) * lotStep, 2);
      lot = MathMax(minLot, MathMin(maxLot, lot));
   }
   else
   {
      lot = CalcLot(slDist);
   }
   if(lot <= 0) return;

   // Envoi ordre
   int cmd    = (signal == 1) ? OP_BUY : OP_SELL;
   string dir = (signal == 1) ? "BUY" : "SELL";

   int ticket = OrderSend(
      Symbol(), cmd, lot, entry, 10,
      NormalizeDouble(sl,  Digits),
      NormalizeDouble(tp1, Digits),
      TradeComment + "_" + dir, MagicNumber, 0,
      (signal == 1) ? clrLime : clrRed
   );

   if(ticket < 0)
   {
      Print("ERREUR OrderSend:", GetLastError(),
            " | ", dir, " | SL:", NormalizeDouble(sl,Digits),
            " | TP1:", NormalizeDouble(tp1,Digits));
   }
   else
   {
      g_TradesToday++;
      g_LastTradeTime = TimeCurrent();
      g_OpenTicket    = ticket;
      g_PartialDone   = false;
      Print("TRADE #", ticket, " | ", dir, " | Lot:", lot,
            " | Entry:", entry,
            " | SL:", NormalizeDouble(sl,Digits),
            " | TP1:", NormalizeDouble(tp1,Digits),
            " | ATR:", DoubleToStr(atr/GetPip(),1), "pips");
   }
}

//+------------------------------------------------------------------+
//| DETECTION SWING HIGH / SWING LOW - 3 bougies (interne)          |
//| Retourne : 1=uptrend (HH+HL), -1=downtrend (LH+LL), 0=unclear  |
//+------------------------------------------------------------------+
int GetSwingBias()
{
   int lookback = 1;    // 1 bougie de chaque cote = swing 3 bougies
   int maxSearch = 150;

   double sh1 = 0, sh2 = 0;
   double sl1 = 0, sl2 = 0;
   int shCount = 0, slCount = 0;

   for(int i = lookback + 1; i < maxSearch - lookback; i++)
   {
      if(shCount >= 2 && slCount >= 2) break;

      double hi = iHigh(Symbol(), PERIOD_M15, i);
      double lo = iLow (Symbol(), PERIOD_M15, i);

      // Swing high : bougie centrale plus haute que voisines
      if(shCount < 2 &&
         iHigh(Symbol(), PERIOD_M15, i-1) < hi &&
         iHigh(Symbol(), PERIOD_M15, i+1) < hi)
      {
         if(shCount == 0) sh1 = hi; else sh2 = hi;
         shCount++;
      }

      // Swing low : bougie centrale plus basse que voisines
      if(slCount < 2 &&
         iLow(Symbol(), PERIOD_M15, i-1) > lo &&
         iLow(Symbol(), PERIOD_M15, i+1) > lo)
      {
         if(slCount == 0) sl1 = lo; else sl2 = lo;
         slCount++;
      }
   }

   if(shCount < 2 || slCount < 2) { Print("SwingBias: manque swings sh=",shCount," sl=",slCount); return 0; }

   bool hh = (sh1 > sh2);
   bool hl = (sl1 > sl2);
   bool lh = (sh1 < sh2);
   bool ll = (sl1 < sl2);

   if(hh && hl) { Print("SwingBias UPTREND   HH=",DoubleToStr(sh1,5)," HL=",DoubleToStr(sl1,5)); return  1; }
   if(lh && ll) { Print("SwingBias DOWNTREND LH=",DoubleToStr(sh1,5)," LL=",DoubleToStr(sl1,5)); return -1; }

   Print("SwingBias RANGE/unclear");
   return 0;
}

//+------------------------------------------------------------------+
//| DETECTION FVG - Fair Value Gap (interne, sans affichage)         |
//| Retourne : 1=FVG haussier, -1=FVG baissier, 0=rien              |
//+------------------------------------------------------------------+
int GetFVGBias()
{
   double curPrice = iClose(Symbol(), PERIOD_M15, 1);

   for(int i = 2; i < 60; i++)
   {
      double hiA = iHigh(Symbol(), PERIOD_M15, i+1); // bougie A (gauche)
      double loA = iLow (Symbol(), PERIOD_M15, i+1);
      double hiC = iHigh(Symbol(), PERIOD_M15, i-1); // bougie C (droite)
      double loC = iLow (Symbol(), PERIOD_M15, i-1);

      // FVG haussier : high[A] < low[C] => gap entre hiA et loC
      if(loC > hiA && curPrice >= hiA && curPrice <= loC)
      {
         Print("FVG Haussier: zone ",DoubleToStr(hiA,5)," - ",DoubleToStr(loC,5));
         return 1;
      }

      // FVG baissier : low[A] > high[C] => gap entre hiC et loA
      if(hiC < loA && curPrice <= loA && curPrice >= hiC)
      {
         Print("FVG Baissier: zone ",DoubleToStr(hiC,5)," - ",DoubleToStr(loA,5));
         return -1;
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| DETECTION WYCKOFF - Spring et Upthrust (interne)                 |
//| Retourne : 1=Spring (BUY), -1=Upthrust (SELL), 0=rien           |
//+------------------------------------------------------------------+
int GetWyckoffSignal()
{
   int    rangeBars = 60;
   double rangeHigh = -999999, rangeLow = 999999;

   // Calcul du range sur les 60 dernières bougies (en excluant la dernière)
   for(int i = 2; i < rangeBars; i++)
   {
      double h = iHigh(Symbol(), PERIOD_M15, i);
      double l = iLow (Symbol(), PERIOD_M15, i);
      if(h > rangeHigh) rangeHigh = h;
      if(l < rangeLow)  rangeLow  = l;
   }

   double atr       = iATR(Symbol(), PERIOD_M15, 14, 1);
   double rangeSize = rangeHigh - rangeLow;

   // Range valide : ni trop grand (tendance) ni trop petit (bruit)
   if(atr <= 0 || rangeSize > 5.0 * atr || rangeSize < 0.5 * atr) return 0;

   double lastLow   = iLow  (Symbol(), PERIOD_M15, 1);
   double lastHigh  = iHigh (Symbol(), PERIOD_M15, 1);
   double lastClose = iClose (Symbol(), PERIOD_M15, 1);

   // Spring : wick casse le bas du range mais la bougie clot au-dessus
   if(lastLow < rangeLow && lastClose > rangeLow)
   {
      Print("Wyckoff SPRING: low=",DoubleToStr(lastLow,5)," rangeLow=",DoubleToStr(rangeLow,5));
      return 1;
   }

   // Upthrust : wick casse le haut du range mais la bougie clot en-dessous
   if(lastHigh > rangeHigh && lastClose < rangeHigh)
   {
      Print("Wyckoff UPTHRUST: high=",DoubleToStr(lastHigh,5)," rangeHigh=",DoubleToStr(rangeHigh,5));
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL PRINCIPAL                                                  |
//| Retourne : 1=BUY, -1=SELL, 0=RIEN                               |
//+------------------------------------------------------------------+
int GetSignal()
{
   // ---- 1. STRUCTURE SWING 3 bougies ----
   int swingBias = GetSwingBias();

   // ---- 2. WYCKOFF Spring / Upthrust (signal fort) ----
   int wyckoff = GetWyckoffSignal();

   // ---- 3. FVG confirmation ----
   int fvg = GetFVGBias();

   // ---- 4. ENTREE M15 : EMA21 + MACD ----
   double m15Ema21  = iMA(Symbol(), PERIOD_M15, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double m15Close1 = iClose(Symbol(), PERIOD_M15, 1);
   if(m15Ema21 <= 0) { Print("BLOQUE: M15 EMA21 invalide"); return 0; }

   double macdMain = iMACD(Symbol(),PERIOD_M15,MACD_Fast,MACD_Slow,MACD_Signal,PRICE_CLOSE,MODE_MAIN,  1);
   double macdSig  = iMACD(Symbol(),PERIOD_M15,MACD_Fast,MACD_Slow,MACD_Signal,PRICE_CLOSE,MODE_SIGNAL,1);
   double hist     = macdMain - macdSig;

   // ---- WYCKOFF : override fort si structure confirme ----
   if(wyckoff == 1 && swingBias != -1)
   {
      Print("SIGNAL BUY [SPRING] swing=",swingBias," fvg=",fvg);
      return 1;
   }
   if(wyckoff == -1 && swingBias != 1)
   {
      Print("SIGNAL SELL [UPTHRUST] swing=",swingBias," fvg=",fvg);
      return -1;
   }

   // ---- SETUP CLASSIQUE : EMA21 + MACD + swing + FVG ----
   bool buySetup  = (m15Close1 > m15Ema21 && hist > 0 && swingBias != -1);
   bool sellSetup = (m15Close1 < m15Ema21 && hist < 0 && swingBias !=  1);

   if(buySetup && fvg >= 0)
   {
      Print("SIGNAL BUY: ema=OK macd=",DoubleToStr(hist,6)," swing=",swingBias," fvg=",fvg);
      return 1;
   }
   if(sellSetup && fvg <= 0)
   {
      // Filtre pente D1 : bloque SHORT si tendance D1 trop haussiere
      double d1EmaFast   = iMA(Symbol(), PERIOD_D1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
      double d1EmaOld    = iMA(Symbol(), PERIOD_D1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 5);
      double d1ATR       = iATR(Symbol(), PERIOD_D1, ATR_Period, 1) / GetPip();
      double d1SlopePips = (d1EmaFast - d1EmaOld) / GetPip();
      double slopeLimit  = d1ATR * ShortSlopeMultiplier;
      if(d1SlopePips >= slopeLimit)
      {
         Print("SELL bloque: pente D1 trop forte (",DoubleToStr(d1SlopePips,0)," >= ",DoubleToStr(slopeLimit,0),")");
         return 0;
      }
      Print("SIGNAL SELL: ema=OK macd=",DoubleToStr(hist,6)," swing=",swingBias," fvg=",fvg," pente=",DoubleToStr(d1SlopePips,0));
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| GESTION TRADES (trailing + partial close)                        |
//+------------------------------------------------------------------+
void ManageTrades()
{
   double pip     = GetPip();
   double beBuf   = BE_Buffer_Pips * pip;
   double minStop = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;

      int    ticket = OrderTicket();
      int    type   = OrderType();
      double op     = OrderOpenPrice();
      double curSL  = OrderStopLoss();
      double curTP  = OrderTakeProfit();
      double lot    = OrderLots();
      double newSL  = curSL;

      double atr = iATR(Symbol(), PERIOD_M15, ATR_Period, 1);
      if(atr <= 0) continue;

      // --- BUY ---
      if(type == OP_BUY)
      {
         double profit   = Bid - op;
         double atrTrail = atr * ATR_Trail_Mult;
         double tp1Dist  = UseFixedSLTP ? FixedTP_Pips * GetPip() : atr * ATR_TP1_Mult;

         // PARTIAL CLOSE : 50% a TP1 si lot dynamique (UseFixedLot=false)
         if(!UseFixedLot && !g_PartialDone && profit >= tp1Dist * 0.9)
         {
            double partLot = NormalizeDouble(lot * 0.5,
               (int)MathRound(MathLog(1.0 / MarketInfo(Symbol(), MODE_LOTSTEP)) / MathLog(10)));
            partLot = MathMax(partLot, MarketInfo(Symbol(), MODE_MINLOT));

            if(partLot < lot)
            {
               if(OrderClose(ticket, partLot, Bid, 10, clrYellow))
               {
                  g_PartialDone = true;
                  Print("PARTIAL CLOSE BUY #", ticket, " | Lot:", partLot,
                        " | Profit pip:", DoubleToStr(profit/pip, 1));
               }
            }
         }

         // BREAK-EVEN apres partial close
         if(UseBE && g_PartialDone && curSL < op)
            newSL = op + beBuf;

         // CHANDELIER EXIT TRAIL (apres BE)
         if(g_PartialDone && curSL >= op)
         {
            double chandelier = Bid - atrTrail;
            if(chandelier > newSL + pip * 2)
               newSL = chandelier;
         }

         // Securite : SL ne depasse pas Bid
         double maxSL = Bid - minStop;
         if(newSL > maxSL) newSL = maxSL;

         // Modification SL si ameliore
         if(newSL > curSL + pip)
         {
            if(!OrderModify(ticket, op, NormalizeDouble(newSL,Digits), curTP, 0, clrYellow))
               Print("Modify BUY err:", GetLastError());
         }
      }

      // --- SELL ---
      else if(type == OP_SELL)
      {
         double profit   = op - Ask;
         double atrTrail = atr * ATR_Trail_Mult;
         double tp1Dist  = UseFixedSLTP ? FixedTP_Pips * GetPip() : atr * ATR_TP1_Mult;

         // PARTIAL CLOSE : 50% a TP1 si lot dynamique (UseFixedLot=false)
         if(!UseFixedLot && !g_PartialDone && profit >= tp1Dist * 0.9)
         {
            double partLot = NormalizeDouble(lot * 0.5,
               (int)MathRound(MathLog(1.0 / MarketInfo(Symbol(), MODE_LOTSTEP)) / MathLog(10)));
            partLot = MathMax(partLot, MarketInfo(Symbol(), MODE_MINLOT));

            if(partLot < lot)
            {
               if(OrderClose(ticket, partLot, Ask, 10, clrYellow))
               {
                  g_PartialDone = true;
                  Print("PARTIAL CLOSE SELL #", ticket, " | Lot:", partLot,
                        " | Profit pip:", DoubleToStr(profit/GetPip(), 1));
               }
            }
         }

         // BREAK-EVEN apres partial close
         // Pour SELL : SL doit descendre vers l entree (op+beBuf = juste au-dessus de l entree)
         if(UseBE && g_PartialDone && curSL > op + beBuf)
            newSL = op + beBuf;

         // CHANDELIER EXIT TRAIL (apres BE : curSL proche de l entree)
         if(g_PartialDone && curSL <= op + beBuf + GetPip())
         {
            double chandelier = Ask + atrTrail;
            if(chandelier < newSL - GetPip() * 2)
               newSL = chandelier;
         }

         // Securite : SL ne descend pas sous Ask + minStop
         double minSL = Ask + minStop;
         if(newSL < minSL) newSL = minSL;

         // Modification SL si ameliore (plus bas = mieux pour SELL)
         if(curSL <= 0 || newSL < curSL - GetPip())
         {
            if(!OrderModify(ticket, op, NormalizeDouble(newSL,Digits), curTP, 0, clrYellow))
               Print("Modify SELL err:", GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CALCUL LOT DYNAMIQUE (risque % fixe)                            |
//+------------------------------------------------------------------+
double CalcLot(double slDist)
{
   double balance  = AccountBalance();
   double riskAmt  = balance * RiskPercent / 100.0;
   double tickVal  = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickVal <= 0 || tickSize <= 0 || slDist <= 0) return 0;

   double lotStep  = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot   = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot   = MarketInfo(Symbol(), MODE_MAXLOT);

   // Valeur monetaire d un pip = tickVal / tickSize * pip
   double pipVal = tickVal / tickSize * GetPip();
   if(pipVal <= 0) return 0;

   double slPips = slDist / GetPip();
   double lot    = riskAmt / (slPips * pipVal);

   lot = NormalizeDouble(MathFloor(lot / lotStep + 0.00001) * lotStep, 2);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//+------------------------------------------------------------------+
//| FILTRES GLOBAUX                                                   |
//+------------------------------------------------------------------+
bool FilterOK()
{
   int spread = (int)MarketInfo(Symbol(), MODE_SPREAD);
   if(spread > SpreadMax)
   {
      Print("BLOQUE spread=", spread, " > max=", SpreadMax);
      return false;
   }

   double atrCur = iATR(Symbol(), PERIOD_M15, ATR_Period, 1);
   double atrAvg = 0;
   for(int i = 2; i <= 21; i++) atrAvg += iATR(Symbol(), PERIOD_M15, ATR_Period, i);
   atrAvg /= 20.0;
   if(atrAvg > 0 && atrCur > atrAvg * ATR_VolatMax)
   {
      Print("BLOQUE volatilite ATR=", DoubleToStr(atrCur/GetPip(),1), " avg=", DoubleToStr(atrAvg/GetPip(),1));
      return false;
   }

   double pip  = GetPip();
   double gap  = MathAbs(iOpen(Symbol(), PERIOD_M15, 0) - iClose(Symbol(), PERIOD_M15, 1));
   if(gap > GapProtectPips * pip)
   {
      Print("BLOQUE gap=", DoubleToStr(gap/pip,1), " > max=", GapProtectPips);
      return false;
   }

   if(UseSessionFilter && !IsInSession())
   {
      Print("BLOQUE hors session");
      return false;
   }

   return true;
}

bool IsInSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int parisH = (dt.hour - BrokerGMT + ParisGMT + 24) % 24;
   return (parisH >= LondonOpen && parisH < LondonClose) ||
          (parisH >= NYOpen     && parisH < NYClose);
}

bool CanTrade()
{
   // Perte journaliere max
   if(GetDailyDrawdown() >= MaxDailyLoss_Pct)
   {
      static bool warned1 = false;
      if(!warned1) { Print("STOP: Perte journaliere max atteinte"); warned1=true; }
      return false;
   }

   // Objectif profit journalier atteint
   double dailyProfit = ((AccountEquity() - g_Balance0) / g_Balance0) * 100.0;
   if(dailyProfit >= MaxDailyProfit_Pct)
   {
      static bool warned2 = false;
      if(!warned2) { Print("OBJECTIF JOUR ATTEINT: +", DoubleToStr(dailyProfit,2), "%"); warned2=true; }
      return false;
   }

   if(g_TradesToday >= MaxTradesPerDay)    return false;
   if(g_ConsecLosses >= MaxConsecLosses)   return false;

   return true;
}

double GetDailyDrawdown()
{
   if(g_Balance0 <= 0) return 0;
   double equity = AccountEquity();
   if(equity >= g_Balance0) return 0;
   return ((g_Balance0 - equity) / g_Balance0) * 100.0;
}

//+------------------------------------------------------------------+
//| SUIVI HISTORIQUE (pertes consecutives)                           |
//+------------------------------------------------------------------+
void UpdateHistory()
{
   int hist = OrdersHistoryTotal();
   if(hist == 0) return;

   // Cherche le trade le plus recent non traite
   for(int i = hist - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      if(OrderTicket() == g_LastTicket) break;

      g_LastTicket    = OrderTicket();
      g_PartialDone   = false; // Reset pour prochain trade
      g_OpenTicket    = -1;

      double result = OrderProfit() + OrderSwap() + OrderCommission();
      if(result < 0)
      {
         g_ConsecLosses++;
         g_LastTradeTime = OrderCloseTime();
         Print("PERTE #", g_ConsecLosses, " consecutive | Ticket:", OrderTicket(),
               " | P&L:", DoubleToStr(result, 2));
      }
      else
      {
         if(g_ConsecLosses > 0)
            Print("Serie pertes terminee (", g_ConsecLosses, ") | Ticket:", OrderTicket());
         g_ConsecLosses = 0;
      }
      break;
   }
}

//+------------------------------------------------------------------+
//| REINITIALISATION JOURNALIERE                                     |
//+------------------------------------------------------------------+
void ResetDaily()
{
   MqlDateTime now, last;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(g_LastDayReset, last);
   if(now.day == last.day) return;

   g_Balance0     = AccountBalance();
   g_TradesToday  = 0;
   g_ConsecLosses = 0;
   g_LastDayReset = TimeCurrent();
   Print("=== NOUVEAU JOUR | Balance:", g_Balance0, " ===");
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                         |
//+------------------------------------------------------------------+
void ShowDashboard()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int parisH = (dt.hour - BrokerGMT + ParisGMT + 24) % 24;

   double atr     = iATR(Symbol(), PERIOD_M15, ATR_Period, 1);
   double pip     = GetPip();
   int    spread  = (int)MarketInfo(Symbol(), MODE_SPREAD);
   double ddPct   = GetDailyDrawdown();
   double profPct = ((AccountEquity() - g_Balance0) / g_Balance0) * 100.0;

   string d1Bias  = (iClose(Symbol(),PERIOD_D1,1) > iMA(Symbol(),PERIOD_D1,EMA_Slow,0,MODE_EMA,PRICE_CLOSE,1))
                    ? "BULL" : "BEAR";
   double h4F     = iMA(Symbol(),PERIOD_H4,EMA_Mid, 0,MODE_EMA,PRICE_CLOSE,1);
   double h4S     = iMA(Symbol(),PERIOD_H4,EMA_Slow,0,MODE_EMA,PRICE_CLOSE,1);
   string h4Trend = (h4F > h4S) ? "BULL" : "BEAR";

   bool   inSess  = IsInSession();
   string sessStr = inSess ? "ACTIF" : "HORS SESSION";

   Comment(
      "=== TrendPulse Pro v1.0 ===\n",
      "Heure France: ", parisH, "h", dt.min, " | Session: ", sessStr, "\n",
      "---\n",
      "D1 Biais : ", d1Bias, "\n",
      "H4 Tendance : ", h4Trend, "\n",
      "ATR M15 : ", DoubleToStr(atr/pip, 1), " pips\n",
      "Spread : ", spread, " / ", SpreadMax, " pips\n",
      "---\n",
      "Trades jour : ", g_TradesToday, " / ", MaxTradesPerDay, "\n",
      "Pertes cons : ", g_ConsecLosses, " / ", MaxConsecLosses, "\n",
      "P&L jour : ", (profPct >= 0 ? "+" : ""), DoubleToStr(profPct, 2), "%\n",
      "Drawdown : ", DoubleToStr(ddPct, 2), "% / ", MaxDailyLoss_Pct, "%\n",
      "---\n",
      "Risque/trade : ", RiskPercent, "%\n",
      "Balance : ", DoubleToStr(AccountBalance(), 2), " ", AccountCurrency(), "\n"
   );
}

//+------------------------------------------------------------------+
//| UTILITAIRES                                                       |
//+------------------------------------------------------------------+
double GetPip()
{
   if(Digits == 5 || Digits == 3) return Point * 10.0;
   if(Digits == 2)                return Point * 10.0; // XAUUSD
   return Point;
}

int CountTrades()
{
   int c = 0;
   for(int i = 0; i < OrdersTotal(); i++)
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
         OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol()) c++;
   return c;
}
//+------------------------------------------------------------------+
