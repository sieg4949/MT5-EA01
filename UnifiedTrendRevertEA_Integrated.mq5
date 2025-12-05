//+------------------------------------------------------------------+
//|                                  UnifiedTrendRevertEA_Integrated.mq5
//|  概要：H1の回帰β×σ（48本）でTRD/RNGを自動判定（ヒステリシス）。
//|        ・TRD：M5ブレイクアウト（HH/LL=6本, Edge≥0.60, 逆指値, EntryBuffer=0.10×ATR(M5)）
//|        ・RNG：M1平均回帰（PF-extreme準拠：|z|≥1.75, VR≤1.02, OU∈[8,60], 時間帯, 指値）
//|        出口は各モジュールのルール＋保険SL（H1ピボット±ATR余剰、ATRキャップ=3.0×ATR(H1)）。
//|  重要：すべての判定は確定バー（shift=1）の値で行う。売買はCTradeを使用。
//|  本版の改善点（セルフレビュー反映）:
//|    1) ヒステリシス状態は lastRegime に一元化（CalcRegimeH1 のstatic排除）
//|    2) ブローカー時計→UTC→JST(+9)補正を追加（InpBrokerUTCOffsetHours）
//|    3) STOP LEVELに加えて FREEZE LEVEL も考慮（保留注文拒否の低減）
//|    4) RNG用の任意SLオプションを追加（既定OFF）
//+------------------------------------------------------------------+
#property strict
#property description "TRDブレイク＋RNG逆張り（自動ゲート／ヒステリシス／ATRキャップ／時差補正／FREEZE対応）"
#property version   "1.2"

#include <Trade/Trade.mqh>

//=========================== 入 力 値 ===============================
// ■ゲート（H1 回帰β×σ）／ヒステリシス
input bool   InpUseHysteresis     = true;     // ヒステリシスを使う
input int    InpBetaWindow        = 48;       // β算出窓（H1本数）
input double InpEnterCoef         = 0.0022;   // TRD入り： |β| ≥ σ×EnterCoef
input double InpExitCoef          = 0.0018;   // RNG戻り： |β| ≤ σ×ExitCoef
input double InpNoHysCoef         = 0.0020;   // ヒステリシスOFF時の単一しきい値

// ■TRD（ブレイクアウト）
input bool   InpEnableTRD         = true;     // TRDモジュール有効
input double InpEntryBufferATR    = 0.10;     // 逆指値バッファ（ATR(M5)×倍率）
input double InpEdgeEntryMin      = 0.60;     // Edgeエントリ下限（0..1）
input int    InpHHLL_Lookback     = 6;        // HH/LL の参照本数（M5）
input int    InpEMA_Fast          = 20;       // Edge用EMA（M5）
input int    InpRSI_Period        = 3;        // RSI3（M5）
input double InpSL_ExtraATR_H1    = 0.12;     // ピボットSLのATR余剰
input double InpATRcapMultiple    = 3.0;      // ATRキャップ（×ATR_H1）
input int    InpSTRUCT_Len        = 3;        // STRUCT連続本数
input double InpBURST_Delta       = 16.0;     // ΔRSIしきい値
input double InpEDGE_Thresh       = 0.28;     // Edge EXITしきい値
input int    InpEDGE_Consec       = 3;        // Edge EXIT連続本数

// ■RNG（平均回帰）
input bool   InpEnableRNG         = true;     // RNGモジュール有効
input double InpZ_in              = 1.75;     // |z| ≥ Z_in で仕掛け
input double InpZ_cut             = 3.0;      // |z| ≥ Z_cut で損切り
input double InpVR_Thr            = 1.02;     // VR ≤ 1.02
input int    InpOU_Min            = 8;        // OU 時間の下限
input int    InpOU_Max            = 60;       // OU 時間の上限
input double InpOffset_ATR        = 0.18;     // 指値オフセット = min(0.18×ATR(M1), 0.6×spread)
input double InpOffset_Spread     = 0.6;      // 同上のスプレッド係数
input int    InpAllowedStartJST   = 17;       // 取引時間（JST）の開始（例17）
input int    InpAllowedEndJST     = 24;       // 取引時間（JST）の終了（例24→0時まで）
input int    InpMaxHold_Min       = 60;       // 最大保有分数（RNG）
input bool   InpRNG_UseSL         = false;    // RNGに任意SLを設定（既定OFF）
input double InpRNG_SL_ATR_H1     = 2.0;      // RNG SL距離（×ATR(H1)）

// ■ブローカー時差
//   例: サーバーがUTC+2 → +2、UTC-3 → -3。これを使って UTC→JST(+9)補正を行う。
input int    InpBrokerUTCOffsetHours = 0;

// ■売買共通
input double InpLots              = 0.10;     // ロット
input int    InpSlippage          = 10;       // スリッページ（ポイント）
input int    InpMagic             = 20251205; // マジックナンバー

//=========================== 内 部 状 態 =============================
CTrade Trade;

string  sym;
ENUM_TIMEFRAMES TF_M1 = PERIOD_M1;
ENUM_TIMEFRAMES TF_M5 = PERIOD_M5;
ENUM_TIMEFRAMES TF_H1 = PERIOD_H1;

// M5（TRD用）
int    hATR_M5 = INVALID_HANDLE;
int    hEMA20  = INVALID_HANDLE;
int    hRSI3   = INVALID_HANDLE;
// H1（SL/ゲート用）
int    hATR_H1 = INVALID_HANDLE;
// M1（RNG用）
int    hATR_M1 = INVALID_HANDLE;
int    hEMA_M1 = INVALID_HANDLE;
int    hSTD_M1 = INVALID_HANDLE;

// Series配列
double M5_open[], M5_high[], M5_low[], M5_close[];
double H1_open[], H1_high[], H1_low[], H1_close[];
double ATR_M5[], EMA20[], RSI3[];
double ATR_H1[];
double M1_close[], EMA_M1[], STD_M1[], ATR_M1[];

// バー更新記録
datetime lastM5BarTime = 0;
datetime lastM1BarTime = 0;

// レジーム
enum Regime { REG_RNG = 0, REG_TRD = 1 };
Regime lastRegime = REG_RNG;   // ← ヒステリシス参照もこの値に統一

//=========================== 関 数 宣 言 =============================
bool   CacheSeries();

Regime CalcRegimeH1();                       // H1ゲート（β×σ、ヒステリシス）
double EdgeScore(int sh);                    // M5 Edge（0..1）
bool   GetHHLL(int sh, double &hh, double &ll);

bool   FindLastPivotLowBelow(double entryPrice, double &pivotLow);
bool   FindLastPivotHighAbove(double entryPrice, double &pivotHigh);
double CalcInitialSL(bool isBuy, double entry);

void   ManagePositionExit_TRD();             // TRD EXIT（STRUCT/BURST/EDGE）
void   TryPlaceBreakoutStops();              // TRD 逆指値

void   ManagePositionExit_RNG(Regime cur);   // RNG EXIT（z/時間/TRD化）
void   TryPlaceMeanRevertLimits(Regime cur); // RNG 指値

bool   AnyOpenPosition();
void   CancelAllPendings();
void   CancelAllPendingsByTag(const string tag);

bool   ComputeZ_VR_OU(int sh, double &z, double &vr, double &ou_time);

int    CurrentHourJST();                     // ブローカー時刻→UTC→JST(+9)

//============================= 初 期 化 ==============================
int OnInit()
{
   sym = _Symbol;

   //--- M5（TRD）
   hATR_M5 = iATR(sym, TF_M5, 14);
   hEMA20  = iMA (sym, TF_M5, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hRSI3   = iRSI(sym, TF_M5, InpRSI_Period, PRICE_CLOSE);
   if(hATR_M5==INVALID_HANDLE || hEMA20==INVALID_HANDLE || hRSI3==INVALID_HANDLE)
   { Print("インジケータ(M5)作成失敗"); return INIT_FAILED; }

   //--- H1（SL/ゲート）
   hATR_H1 = iATR(sym, TF_H1, 14);
   if(hATR_H1==INVALID_HANDLE)
   { Print("インジケータ(H1 ATR)作成失敗"); return INIT_FAILED; }

   //--- M1（RNG）
   hATR_M1 = iATR(sym, TF_M1, 14);
   hEMA_M1 = iMA (sym, TF_M1, 48, 0, MODE_EMA, PRICE_CLOSE);        // Zの中心
   hSTD_M1 = iStdDev(sym, TF_M1, 48, 0, MODE_SMA, PRICE_CLOSE);     // Zのσ
   if(hATR_M1==INVALID_HANDLE || hEMA_M1==INVALID_HANDLE || hSTD_M1==INVALID_HANDLE)
   { Print("インジケータ(M1)作成失敗"); return INIT_FAILED; }

   lastM5BarTime = iTime(sym, TF_M5, 0);
   lastM1BarTime = iTime(sym, TF_M1, 0);

   Print("初期化完了（TRD＋RNG統合 v1.2）");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("終了：", reason);
}

//============================= 毎 テ ィ ッ ク =========================
void OnTick()
{
   // 参照配列の更新（取得失敗なら抜け）
   if(!CacheSeries()) return;

   // H1ゲート（確定バーでβ×σ計算、ヒステリシスは lastRegime 参照）
   Regime regime = CalcRegimeH1();
   if(regime != lastRegime)
   {
      PrintFormat("H1 Regime 変更: %s -> %s",
                  lastRegime==REG_TRD?"TRD":"RNG",
                  regime==REG_TRD?"TRD":"RNG");
      // 状態遷移バーでは新規発注を抑制。安全のため保留注文は一旦全キャンセル。
      CancelAllPendings();
      lastRegime = regime;
   }

   // ==== M5 新バー（TRDモジュール）====
   datetime curM5 = iTime(sym, TF_M5, 0);
   if(curM5 != lastM5BarTime)
   {
      lastM5BarTime = curM5;

      // 既存TRDポジのEXIT（STRUCT/BURST/EDGE）※確定M5で判定
      ManagePositionExit_TRD();

      // TRD：新規逆指値（1ポジ制御・確定値判定）
      if(InpEnableTRD && regime==REG_TRD && !AnyOpenPosition())
         TryPlaceBreakoutStops();
   }

   // ==== M1 新バー（RNGモジュール）====
   datetime curM1 = iTime(sym, TF_M1, 0);
   if(curM1 != lastM1BarTime)
   {
      lastM1BarTime = curM1;

      // 既存RNGポジのEXIT（z/時間/TRD化）
      ManagePositionExit_RNG(regime);

      // RNG：新規指値（1ポジ制御・確定値判定）
      if(InpEnableRNG && regime==REG_RNG && !AnyOpenPosition())
         TryPlaceMeanRevertLimits(regime);
   }
}

//============================= データ取得 =============================
bool CacheSeries()
{
   // --- M5
   int m5ToCopy = MathMax(InpHHLL_Lookback+10, 120);
   if(CopyOpen (sym, TF_M5, 0, m5ToCopy, M5_open)  <= 0) return false;
   if(CopyHigh (sym, TF_M5, 0, m5ToCopy, M5_high)  <= 0) return false;
   if(CopyLow  (sym, TF_M5, 0, m5ToCopy, M5_low)   <= 0) return false;
   if(CopyClose(sym, TF_M5, 0, m5ToCopy, M5_close) <= 0) return false;
   if(CopyBuffer(hATR_M5, 0, 0, m5ToCopy, ATR_M5)  <= 0) return false;
   if(CopyBuffer(hEMA20 , 0, 0, m5ToCopy, EMA20 )  <= 0) return false;
   if(CopyBuffer(hRSI3  , 0, 0, m5ToCopy, RSI3  )  <= 0) return false;

   ArraySetAsSeries(M5_open,  true); ArraySetAsSeries(M5_high, true);
   ArraySetAsSeries(M5_low,   true); ArraySetAsSeries(M5_close,true);
   ArraySetAsSeries(ATR_M5,   true); ArraySetAsSeries(EMA20,   true);
   ArraySetAsSeries(RSI3,     true);

   // --- H1
   int h1ToCopy = MathMax(InpBetaWindow+10, 120);
   if(CopyOpen (sym, TF_H1, 0, h1ToCopy, H1_open)   <= 0) return false;
   if(CopyHigh (sym, TF_H1, 0, h1ToCopy, H1_high)   <= 0) return false;
   if(CopyLow  (sym, TF_H1, 0, h1ToCopy, H1_low)    <= 0) return false;
   if(CopyClose(sym, TF_H1, 0, h1ToCopy, H1_close)  <= 0) return false;
   if(CopyBuffer(hATR_H1, 0, 0, h1ToCopy, ATR_H1)   <= 0) return false;

   ArraySetAsSeries(H1_open,  true); ArraySetAsSeries(H1_high, true);
   ArraySetAsSeries(H1_low,   true); ArraySetAsSeries(H1_close,true);
   ArraySetAsSeries(ATR_H1,   true);

   // --- M1
   int m1ToCopy = 400; // Z/VR/OUの計算に十分な本数
   if(CopyClose(sym, TF_M1, 0, m1ToCopy, M1_close)   <= 0) return false;
   if(CopyBuffer(hEMA_M1, 0, 0, m1ToCopy, EMA_M1)    <= 0) return false;
   if(CopyBuffer(hSTD_M1, 0, 0, m1ToCopy, STD_M1)    <= 0) return false;
   if(CopyBuffer(hATR_M1, 0, 0, m1ToCopy, ATR_M1)    <= 0) return false;

   ArraySetAsSeries(M1_close, true); ArraySetAsSeries(EMA_M1, true);
   ArraySetAsSeries(STD_M1,   true); ArraySetAsSeries(ATR_M1, true);

   return true;
}

//============================= H1ゲート ==============================
// 回帰傾きβと窓内σを求め、ヒステリシス（lastRegime）でTRD/RNGを安定切替。
// すべて確定バー（shift=1）で評価。データ不足時は安全側（RNG）。
//====================================================================
Regime CalcRegimeH1()
{
   int bars = ArraySize(H1_close);
   if(bars < InpBetaWindow+1) return REG_RNG;

   int shift = 1;
   int start = shift + InpBetaWindow - 1;

   int N = InpBetaWindow;
   double xMean=0.0, xVar=0.0;
   for(int i=0;i<N;i++) xMean += i;
   xMean /= N;
   for(int j=0;j<N;j++){ double d=j-xMean; xVar += d*d; }
   xVar /= N;

   double yMean=0.0;
   for(int k=0;k<N;k++) yMean += H1_close[start - k];
   yMean /= N;

   double cov=0.0, varY=0.0;
   for(int t=0;t<N;t++)
   {
      double y  = H1_close[start - t];
      double xi = t;
      cov  += (xi - xMean)*(y - yMean);
      varY += (y - yMean)*(y - yMean);
   }
   cov  /= N;
   varY /= N;

   double beta  = (xVar>0.0 ? cov/xVar : 0.0);
   double sigma = MathSqrt(varY);

   Regime cur;
   if(InpUseHysteresis)
   {
      // ← ここが修正点：内部static廃止、lastRegimeを参照
      if(lastRegime==REG_RNG)  cur = (MathAbs(beta) >= sigma*InpEnterCoef) ? REG_TRD : REG_RNG;
      else                     cur = (MathAbs(beta) <= sigma*InpExitCoef ) ? REG_RNG : REG_TRD;
   }
   else
   {
      cur = (MathAbs(beta) >= sigma*InpNoHysCoef) ? REG_TRD : REG_RNG;
   }
   return cur;
}

//============================= Edge(M5) ==============================
// 位置=(close-EMA20)/(2*ATR)、傾き=(EMA20-EMA20[3])/(3*ATR) を[-1,1]→0..1へ。
// RSI3は0..1、簡略構造スコア{0,0.5,1}を加重合成。重み：0.35/0.25/0.25/0.15
//====================================================================
double EdgeScore(int sh)
{
   if(ArraySize(M5_close) <= sh+3 || ATR_M5[sh] <= 0.0) return 0.0;

   double pos_raw   = (M5_close[sh] - EMA20[sh]) / (2.0*ATR_M5[sh]);
   double slope_raw = (EMA20[sh]    - EMA20[sh+3])/(3.0*ATR_M5[sh]);

   // クリップ→0..1
   double pos_norm   = (MathMax(-1.0, MathMin(1.0, pos_raw))   + 1.0)/2.0;
   double slope_norm = (MathMax(-1.0, MathMin(1.0, slope_raw)) + 1.0)/2.0;

   double rsi_norm = MathMax(0.0, MathMin(100.0, RSI3[sh]))/100.0;

   // 簡略構造スコア（直近1本の形）
   double s=0.0;
   if(ArraySize(M5_high)>sh+3 && ArraySize(M5_low)>sh+3)
   {
      double h2=M5_high[sh+2], h3=M5_high[sh+3];
      double l2=M5_low [sh+2], l3=M5_low [sh+3];
      bool up = (M5_high[sh+1] > MathMax(h2,h3)) && (M5_low[sh+1] >= MathMin(l2,l3));
      bool dn = (M5_low [sh+1] < MathMin(l2,l3)) && (M5_high[sh+1] <= MathMax(h2,h3));
      if(up != dn) s=1.0; else if(up && dn) s=0.5;
   }

   return 0.35*pos_norm + 0.25*slope_norm + 0.25*rsi_norm + 0.15*s;
}

//============================= HH/LL(M5) ============================
// 直近L本（shift=1..L）の高値最大/安値最小を返す（確定バーで1本シフト）
//====================================================================
bool GetHHLL(int sh, double &hh, double &ll)
{
   int L = InpHHLL_Lookback;
   if(ArraySize(M5_high) <= sh+L || ArraySize(M5_low) <= sh+L) return false;

   double mx = -DBL_MAX, mn = DBL_MAX;
   for(int i=1;i<=L;i++)
   {
      mx = MathMax(mx, M5_high[sh+i]);
      mn = MathMin(mn, M5_low [sh+i]);
   }
   hh = mx; ll = mn;
   return true;
}

//============================= ピボット(H1) =========================
// 左右=3本のユニーク極値。entryを基準に、BUYは下の安値、SELLは上の高値を直近から探索。
//====================================================================
bool FindLastPivotLowBelow(double entryPrice, double &pivotLow)
{
   int K=3, sz=ArraySize(H1_low);
   for(int i=K+1; i<sz-K; ++i)
   {
      double lv = H1_low[i];
      bool isMin=true;
      for(int j=1;j<=K;j++){ if(!(lv < H1_low[i-j] && lv < H1_low[i+j])){ isMin=false; break; } }
      if(isMin && lv < entryPrice){ pivotLow=lv; return true; }
   }
   return false;
}
bool FindLastPivotHighAbove(double entryPrice, double &pivotHigh)
{
   int K=3, sz=ArraySize(H1_high);
   for(int i=K+1; i<sz-K; ++i)
   {
      double hv = H1_high[i];
      bool isMax=true;
      for(int j=1;j<=K;j++){ if(!(hv > H1_high[i-j] && hv > H1_high[i+j])){ isMax=false; break; } }
      if(isMax && hv > entryPrice){ pivotHigh=hv; return true; }
   }
   return false;
}

//============================= 初期SL ===============================
// ピボット±(SL_Extra×ATR_H1)、見つからなければ(2.5+SL_Extra)×ATR_H1。
// ATRキャップ適用：BUYは max(pivotSL, entry-ATRcap×ATR_H1)、SELLは min(..., entry+...)
//====================================================================
double CalcInitialSL(bool isBuy, double entry)
{
   if(ArraySize(ATR_H1)<=1) return 0.0;
   double atrh = ATR_H1[1];
   if(atrh<=0.0) return 0.0;

   if(isBuy)
   {
      double sl_pivot;
      double pLow;
      if(FindLastPivotLowBelow(entry, pLow)) sl_pivot = pLow - InpSL_ExtraATR_H1*atrh;
      else                                   sl_pivot = entry - (2.5 + InpSL_ExtraATR_H1)*atrh;

      double sl_cap = entry - InpATRcapMultiple*atrh;
      return MathMax(sl_pivot, sl_cap);
   }
   else
   {
      double sl_pivot;
      double pHigh;
      if(FindLastPivotHighAbove(entry, pHigh)) sl_pivot = pHigh + InpSL_ExtraATR_H1*atrh;
      else                                     sl_pivot = entry + (2.5 + InpSL_ExtraATR_H1)*atrh;

      double sl_cap = entry + InpATRcapMultiple*atrh;
      return MathMin(sl_pivot, sl_cap);
   }
}

//============================= TRD EXIT =============================
// 構造（直近3本の連続逆行）→ BURST(ΔRSI) → EDGE(閾値連続) の優先で成行決済。
//====================================================================
void ManagePositionExit_TRD()
{
   if(!PositionSelect(sym)) return;
   if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) return;

   string cmt = PositionGetString(POSITION_COMMENT);
   if(StringFind(cmt, "TRD_", 0) < 0) return; // TRDポジのみ対象

   long type = PositionGetInteger(POSITION_TYPE);
   int  sh   = 1;

   if(ArraySize(M5_low)<=sh+InpSTRUCT_Len || ArraySize(RSI3)<=sh+2) return;

   bool doExit=false;

   // 1) STRUCT（3本連続の反対方向）
   if(type==POSITION_TYPE_BUY)
   {
      bool downSeq=true;
      for(int k=0;k<InpSTRUCT_Len-1;k++)
         if(!(M5_low[sh+k] < M5_low[sh+k+1])){ downSeq=false; break; }
      if(downSeq) doExit=true;
   }
   else if(type==POSITION_TYPE_SELL)
   {
      bool upSeq=true;
      for(int k=0;k<InpSTRUCT_Len-1;k++)
         if(!(M5_high[sh+k] > M5_high[sh+k+1])){ upSeq=false; break; }
      if(upSeq) doExit=true;
   }

   // 2) BURST（ΔRSI）
   if(!doExit)
   {
      double d = RSI3[sh] - RSI3[sh+1];
      if((type==POSITION_TYPE_BUY  && d <= -InpBURST_Delta) ||
         (type==POSITION_TYPE_SELL && d >=  InpBURST_Delta)) doExit=true;
   }

   // 3) EDGE（弱化継続）
   if(!doExit)
   {
      bool under=true;
      for(int k=0;k<InpEDGE_Consec;k++)
      {
         double e = EdgeScore(sh+k);
         if(e >= InpEDGE_Thresh){ under=false; break; }
      }
      if(under) doExit=true;
   }

   if(doExit)
   {
      bool ok = Trade.PositionClose(sym, InpSlippage);
      if(!ok) Print("TRD EXIT失敗: ", _LastError);
   }
}

//============================= TRD 逆指値 ===========================
// 確定M5で条件成立 → 次バー用にBuyStop/SellStopを置く。
// STOP LEVEL と FREEZE LEVEL を考慮して価格を調整。
//====================================================================
void TryPlaceBreakoutStops()
{
   // TRD系保留を先に削除（置き直し）
   CancelAllPendingsByTag("TRD_");

   int sh = 1;
   double edge = EdgeScore(sh);
   if(edge < InpEdgeEntryMin) return;

   double hh,ll;
   if(!GetHHLL(sh, hh, ll)) return;

   double c   = M5_close[sh];
   double atr = ATR_M5[sh];
   if(atr<=0.0) return;

   double buf = InpEntryBufferATR * atr;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt     = SymbolInfoDouble(sym, SYMBOL_POINT);
   double stops  = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double freeze = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minPts = MathMax(stops, freeze);

   MqlTick tk; SymbolInfoTick(sym, tk);

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpSlippage);

   // BUY STOP：close>HH → BuyStop=HH+buf
   if(c > hh)
   {
      double price = NormalizeDouble(hh + buf, digits);
      // 最小距離（stop/freeze）を確保
      if(minPts>0 && (price - tk.ask) < minPts*pt) price = tk.ask + minPts*pt;

      double sl = CalcInitialSL(true, price);
      bool ok = Trade.BuyStop(InpLots, price, sym, sl, 0.0, ORDER_TIME_GTC, 0, "TRD_BUYSTOP");
      if(!ok) Print("BuyStop失敗:", _LastError);
   }
   // SELL STOP：close<ll → SellStop=LL-buf
   else if(c < ll)
   {
      double price = NormalizeDouble(ll - buf, digits);
      if(minPts>0 && (tk.bid - price) < minPts*pt) price = tk.bid - minPts*pt;

      double sl = CalcInitialSL(false, price);
      bool ok = Trade.SellStop(InpLots, price, sym, sl, 0.0, ORDER_TIME_GTC, 0, "TRD_SELLSTOP");
      if(!ok) Print("SellStop失敗:", _LastError);
   }
}

//============================= RNG EXIT =============================
// |z|≤0.15 TP ／ |z|≥Z_cut LC ／ TRD化 LC ／ 最大保有時間超過 LC
//====================================================================
void ManagePositionExit_RNG(Regime cur)
{
   if(!PositionSelect(sym)) return;
   if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) return;

   string cmt = PositionGetString(POSITION_COMMENT);
   if(StringFind(cmt, "RNG_", 0) < 0) return; // RNGポジのみ

   // 1) TRD化したら強制クローズ
   if(cur==REG_TRD)
   {
      bool ok=Trade.PositionClose(sym, InpSlippage);
      if(!ok) Print("RNG EXIT(TRD化)失敗:", _LastError);
      return;
   }

   // 2) z/VR/OU（確定M1=shift=1）
   int sh=1;
   double z, vr, ou;
   if(!ComputeZ_VR_OU(sh, z, vr, ou)) return;

   // 3) 条件判定
   bool doExit=false;
   if(MathAbs(z) <= 0.15) doExit=true;         // 中心復帰
   if(MathAbs(z) >= InpZ_cut) doExit=true;     // 拡散

   // 4) 最大保有時間
   datetime etime = (datetime)PositionGetInteger(POSITION_TIME);
   int heldMin = (int)MathFloor((TimeCurrent() - etime)/60.0);
   if(heldMin >= InpMaxHold_Min) doExit=true;

   if(doExit)
   {
      bool ok=Trade.PositionClose(sym, InpSlippage);
      if(!ok) Print("RNG EXIT失敗:", _LastError);
   }
}

//============================= RNG 指値 =============================
// 時間帯（JST）・VR・OU・|z|を満たした場合に BuyLimit / SellLimit を設置。
// 価格は offset = min(0.18×ATR(M1), 0.6×spread)。STOP/FREEZE距離を確保。
// 任意SL（InpRNG_UseSL=true）時は H1 ATR に対する±距離でSL設定。
//====================================================================
void TryPlaceMeanRevertLimits(Regime cur)
{
   // RNG系保留を先に削除（置き直し）
   CancelAllPendingsByTag("RNG_");

   // 時間帯（JST）判定
   int hourJST = CurrentHourJST();
   bool inHours=false;
   if(InpAllowedStartJST <= InpAllowedEndJST)
      inHours = (hourJST >= InpAllowedStartJST && hourJST <= InpAllowedEndJST);
   else
      inHours = (hourJST >= InpAllowedStartJST || hourJST <= InpAllowedEndJST);
   if(!inHours) return;

   // 指標（確定M1）
   int sh=1;
   double z, vr, ou;
   if(!ComputeZ_VR_OU(sh, z, vr, ou)) return;
   if(vr > InpVR_Thr) return;
   if(!(ou >= InpOU_Min && ou <= InpOU_Max)) return;
   if(MathAbs(z) < InpZ_in) return;

   // 価格要素
   MqlTick tk; SymbolInfoTick(sym, tk);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt     = SymbolInfoDouble(sym, SYMBOL_POINT);
   double stops  = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double freeze = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minPts = MathMax(stops, freeze);

   double spread = tk.ask - tk.bid;
   double offAtr = InpOffset_ATR * ATR_M1[sh];
   double offSpr = InpOffset_Spread * spread;
   double offset = (offAtr < offSpr ? offAtr : offSpr);
   if(offset <= 0.0) return;

   // 任意SLの事前取得（H1 ATR）
   double rngSL = 0.0;
   if(InpRNG_UseSL && ArraySize(ATR_H1)>1)
      rngSL = InpRNG_SL_ATR_H1 * ATR_H1[1];

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpSlippage);

   // z<=-Z_in → BUY LIMIT（bid - offset）
   if(z <= -InpZ_in)
   {
      double price = NormalizeDouble(tk.bid - offset, digits);
      // STOP/FREEZE距離：現在のBidより下に置くので (tk.bid - price) >= minPts*pt
      if(minPts>0 && (tk.bid - price) < minPts*pt)
         price = tk.bid - minPts*pt;

      double sl = 0.0;
      if(InpRNG_UseSL && rngSL>0.0) sl = price - rngSL; // BuyLimitのSLは下側

      bool ok = Trade.BuyLimit(InpLots, price, sym, sl, 0.0, ORDER_TIME_GTC, 0, "RNG_BUYLIMIT");
      if(!ok) Print("RNG BuyLimit失敗:", _LastError);
   }
   // z>=+Z_in → SELL LIMIT（ask + offset）
   else if(z >= InpZ_in)
   {
      double price = NormalizeDouble(tk.ask + offset, digits);
      // STOP/FREEZE距離：現在のAskより上に置くので (price - tk.ask) >= minPts*pt
      if(minPts>0 && (price - tk.ask) < minPts*pt)
         price = tk.ask + minPts*pt;

      double sl = 0.0;
      if(InpRNG_UseSL && rngSL>0.0) sl = price + rngSL; // SellLimitのSLは上側

      bool ok = Trade.SellLimit(InpLots, price, sym, sl, 0.0, ORDER_TIME_GTC, 0, "RNG_SELLLIMIT");
      if(!ok) Print("RNG SellLimit失敗:", _LastError);
   }
}

//============================= Z / VR / OU ==========================
// z   = (close - EMA)/STD（48）
// VR  = Var(5分差分)/[5*Var(1分差分)]（窓=60）
// OU  = AR(1)係数 φ から -1/ln(φ)（0<φ<1のとき）。範囲外は大値（9999）で無効扱い。
//====================================================================
bool ComputeZ_VR_OU(int sh, double &z, double &vr, double &ou_time)
{
   if(ArraySize(M1_close)<=sh+60 || ArraySize(EMA_M1)<=sh+1 || ArraySize(STD_M1)<=sh+1)
      return false;

   double mu    = EMA_M1[sh];
   double sigma = STD_M1[sh];
   if(sigma<=0.0 || sigma==EMPTY_VALUE) return false;

   z = (M1_close[sh] - mu)/sigma;

   // VR（窓=60、n=5）
   int W=60, n=5;
   double m1=0, v1=0; int c1=0;
   for(int i=sh+W; i>sh+1; --i)
   {
      double r1 = M1_close[i-1] - M1_close[i];
      m1 += r1; v1 += r1*r1; c1++;
   }
   if(c1<2) return false;
   double var1 = (v1 - (m1*m1)/c1)/(c1-1);
   if(var1<=0.0) return false;

   double m5=0, v5=0; int c5=0;
   for(int j=sh+W; j>sh+n; --j)
   {
      double r5 = M1_close[j-n] - M1_close[j];
      m5 += r5; v5 += r5*r5; c5++;
   }
   if(c5<2) return false;
   double var5 = (v5 - (m5*m5)/c5)/(c5-1);

   vr = var5/(n*var1);

   // OU：x_t = φ x_{t-1} + ε（切片省略の簡易推定）
   double sxx=0, sxy=0; int cnt=0;
   for(int k=sh+W; k>sh+1; --k)
   {
      double xt  = M1_close[k-1] - EMA_M1[k-1];
      double xt1 = M1_close[k]   - EMA_M1[k];
      sxx += xt1*xt1;
      sxy += xt1*xt;
      cnt++;
   }
   if(sxx<=0.0 || cnt<10){ ou_time = 9999; return true; }
   double phi = sxy/sxx;
   if(phi<=0.0 || phi>=1.0) ou_time = 9999;
   else                     ou_time = -1.0/MathLog(phi);
   return true;
}

//============================= JST現在時 ============================
// ブローカー時刻（TimeCurrent）→ 入力オフセットでUTC → JST(+9) へ変換して hour を返す。
//====================================================================
int CurrentHourJST()
{
   datetime nowSrv = TimeCurrent();
   datetime nowUTC = nowSrv - InpBrokerUTCOffsetHours*60*60;
   datetime nowJST = nowUTC + 9*60*60;
   MqlDateTime md; TimeToStruct(nowJST, md);
   return md.hour;
}

//============================= 注文管理 ==============================
bool AnyOpenPosition()
{
   if(!PositionSelect(sym)) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) return false;
   return true;
}

void CancelAllPendings()
{
   int total=OrdersTotal();
    for(int i=total-1; i>=0; --i)
    {
       // MQL5ではOrderSelectはチケット番号のみを受け取るため、先にインデックスからチケットを取得する
       // OrderGetTicketは現在のオーダープール(MODE_TRADES相当)に存在するオーダーのチケットを返す
       ulong ticket = OrderGetTicket(i);
       if(ticket==0)               continue; // 無効チケットをスキップ
       if(!OrderSelect(ticket))    continue; // チケットに紐付くオーダーがなければ次へ
       if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue; // EA専用のマジック番号でなければ対象外
       if(OrderGetString(ORDER_SYMBOL)!=sym)      continue; // 他シンボルの注文は削除しない

       int type=(int)OrderGetInteger(ORDER_TYPE);
       // 指値・逆指値のみ削除対象とし、成行注文への影響を防ぐ
       if(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_SELL_LIMIT ||
          type==ORDER_TYPE_BUY_STOP  || type==ORDER_TYPE_SELL_STOP )
       {
          Trade.OrderDelete(ticket); // 選択済みのチケットを削除
       }
    }
}

void CancelAllPendingsByTag(const string tag)
{
   int total=OrdersTotal();
    for(int i=total-1; i>=0; --i)
    {
       // チケット取得→選択の順で処理することで、MQL5のOrderSelect仕様に適合させる
       ulong ticket = OrderGetTicket(i);
       if(ticket==0)               continue; // 取得失敗時はスキップ
       if(!OrderSelect(ticket))    continue; // 選択不可の場合は次へ
       if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue; // 他EA/手動注文を除外
       if(OrderGetString(ORDER_SYMBOL)!=sym)      continue; // シンボル違いを除外

       string c = OrderGetString(ORDER_COMMENT);
       // コメントの先頭に指定タグが含まれる注文のみ削除対象
       if(StringFind(c, tag, 0) == 0)
       {
          int type=(int)OrderGetInteger(ORDER_TYPE);
          if(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_SELL_LIMIT ||
             type==ORDER_TYPE_BUY_STOP  || type==ORDER_TYPE_SELL_STOP )
          {
             Trade.OrderDelete(ticket); // タグ一致の指値・逆指値を削除
          }
       }
    }
}
