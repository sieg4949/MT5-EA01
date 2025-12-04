//+------------------------------------------------------------------+
//|                                                TrendRevFilter.mq5|
//|                                   (c) 2025 Shigure & "投機" Project|
//+------------------------------------------------------------------+
// このEAは「順張りエントリー + 逆張りフィルタ(ベトー)」方式です。
// ・逆張りロジックでは注文しません（フィルタで“入らない判断”だけを行う）
// ・全ての判定は確定バー（shift=1）の値で実施（未確定禁止）
// ・上位足(H1)でトレンド文脈、M1でエントリー/決済
// ・CTradeを用いて売買
// ・コメントは詳細に（後から読んでも分かるように）
//+------------------------------------------------------------------+
#property strict
#property description "Trend-Following with Reverse Veto Filter (H1 context / M1 trade)"
#property version   "1.00"          // MQL5 Marketのバージョン表記規約に合わせて「xxx.yy」形式へ修正
#property link      ""

// 標準ライブラリ
#include <Trade/Trade.mqh>

//==================================================================
// ■ 入力パラメータ（必要に応じて調整可）
//==================================================================

// ---- 取引基本設定 ----
input double   InpLots              = 0.10;   // ロット
input int      InpSlippagePoints    = 20;     // 許容スリッページ（ポイント）
input ulong    InpMagic             = 20251204; // マジックナンバー
input bool     InpLongAllowed       = true;   // 買い許可
input bool     InpShortAllowed      = true;   // 売り許可
input bool     InpOnePositionOnly   = true;   // 同時1ポジ制限（true推奨）

// ---- 時間足・データ長 ----
input ENUM_TIMEFRAMES  TF_Trade     = PERIOD_M1;   // 取引用（M1固定推奨）
input ENUM_TIMEFRAMES  TF_Context   = PERIOD_H1;   // 文脈用（H1）
input int      LookbackBars_M1      = 5000;        // M1で確保する最少本数
input int      LookbackBars_H1      = 1000;        // H1で確保する最少本数

// ---- インジ期間（M1系） ----
input int      ATR_Period_M1        = 30;    // ATR(M1)
input int      EMA_Period_M1        = 50;    // EMA(M1)
input int      Donchian_Period      = 40;    // ドンチャン(過去n本の高安)
input int      ZShort_Period        = 90;    // 近似z-score用(短期)
input int      ZLong_Period         = 240;   // 近似z-score用(長期)
input int      CLV_Sum_Period       = 15;    // CLV累積(モメンタム)
input int      RSI_Period           = 21;    // RSI
input int      MACD_Fast            = 12;    // MACD FastEMA
input int      MACD_Slow            = 26;    // MACD SlowEMA
input int      MACD_Signal          = 9;     // MACD Signal

// ---- インジ期間（H1系・文脈） ----
input int      H1_EMA_Period        = 50;    // H1 EMA
input int      H1_ADX_Period        = 14;    // H1 ADX
input int      H1_R2_Period         = 50;    // H1 近似R^2（EMA傾きと一緒に使用）

// ---- 順張り ENTRY/EXIT スコアリング ----
input int      ENTRY_T              = 2;     // エントリースコア閾値（買い>= +2 / 売り<= -2）
input int      EXIT_T               = 4;     // エグジットスコア閾値
input double   R2_GATE              = 0.25;  // H1 R^2最低値
input double   H1_Slope_Min         = 0.03;  // H1 EMA傾き 最低絶対値
input double   RealBody_Min_ATR     = 0.10;  // 実体の最小（ATR比）…小さすぎる足は無効
input double   Wick_Max_ATR         = 0.30;  // 逆ヒゲ最大（ATR比）…逆行圧強すぎ足は無効
input double   Pullback_Min_ATR     = 0.10;  // プルバック最小（ATR比）
input double   Pullback_Max_ATR     = 0.70;  // プルバック最大（ATR比）

// ---- EXIT（保険）----
input double   FastAdverse_ATR      = 0.40;  // 逆行即切りの距離（ATR）
input double   VWAP_Exit_ATR        = 1.30;  // 長期zが張り付き＋VWAP距離で離脱
input int      TimeScoreBars        = 2000;  // 長期保有のスコア加点開始
input int      ForceExitBars        = 3000;  // どれだけ良くてもここで強制クローズ

// ---- 逆張りフィルタ（ベトーのみ / エントリーはしない） ----
// * A/B & Grid 検証のベスト案：REV_T=3, dev2=1.8, vwap2=2.0, rsi_ext=15, pin_wick_min=0.4
input int      REV_T                = 3;     // ベトー判定の合計スコア閾値
input double   Rev_dev1_ATR         = 1.2;   // EMA乖離の弱(+1)判定
input double   Rev_dev2_ATR         = 1.8;   // EMA乖離の強(+2)判定
input double   Rev_vwap1_ATR        = 1.4;   // VWAP距離の弱(+1)判定
input double   Rev_vwap2_ATR        = 2.0;   // VWAP距離の強(+2)判定
input int      Rev_RSI_Extreme      = 15;    // RSI極端（<=15 or >=85）
input double   Rev_Pin_WickMin_ATR  = 0.4;   // ピンバーのヒゲ下限（ATR比）
input double   Rev_Pin_BodyMax_ATR  = 0.2;   // ピンバー実体上限（ATR比）

// ---- チャートパネル表示 ----
// Comment()ではフォント指定が効かないため、デフォルトでOBJ_LABELを使用してフォントとサイズを変更可能にする。
// 軽量表示を優先したい場合のみ、明示的にUseCustomPanelLabel=falseへ切り替える。
input bool     UseCustomPanelLabel  = true;        // true: OBJ_LABELでフォント/サイズを自由に変更（推奨）、false: Commentで軽量表示（フォント固定）
input string   PanelFontName        = "Meiryo UI"; // 日本語が文字化けしないフォントをデフォルトに設定（UseCustomPanelLabel=true時のみ有効）
input int      PanelFontSize        = 10;          // パネルのフォントサイズ（同上）
input color    PanelFontColor       = clrWhite;    // 文字色（同上）
input ENUM_BASE_CORNER PanelCorner  = CORNER_LEFT_UPPER; // 配置コーナー（同上）
input int      PanelXOffset         = 10;          // コーナーからのXオフセット（px）
input int      PanelYOffset         = 10;          // コーナーからのYオフセット（px）

//==================================================================
// ■ 変数・オブジェクト
//==================================================================
CTrade trade;

MqlTick last_tick;
datetime last_bar_time = 0;

// 「NAN」相当の値を明示的に用意（ビルド環境で未定義だったため自前で保持）
//  ※コンパイル時定数で0除算を行うと「0.0 - division by zero」エラーになるため、
//    実行時に安全な計算でNaNを生成しグローバルに保持する。
double NaNValue = 0.0;             // OnInitでMathSqrt(-1.0)を使ってNaNへ差し替える

int DigitsAdjust = 1;           // USDJPYなどを想定（1pips=0.01）
double PointPips = 0.01;        // 1pips相当
double SpreadPips= 0.1;         // スプレッド（pips換算の想定値）※必要なら動的取得に変更可

// ポジション管理
bool   hasPosition   = false;
int    posDir        = 0;       // +1 BUY / -1 SELL
double posEntryPrice = 0.0;
long   posTicket     = -1;
int    posBars       = 0;
double posMFE        = 0.0;     // pips
double posMAE        = 0.0;     // pips

// チャート表示用の最新スコア保持（直近確定バーの評価結果をそのまま見られるようにする）
//  ・内部計算では整数で加点しているが、表示側は double に統一し小数付きで示すことで
//    「丸めや型変換による見落とし」を防ぎ、表示と内部判定の型差異をなくす。
double lastRevBuyScore  = 0.0;  // SELL方向の逆張りスコア（SELLを試みる際のveto値）
double lastRevSellScore = 0.0;  // BUY方向の逆張りスコア（BUYを試みる際のveto値）
double lastEntryScore   = 0.0;  // 順張りエントリースコア
bool   lastBuyGate      = false;// H1文脈ゲート（BUY可否）
bool   lastSellGate     = false;// H1文脈ゲート（SELL可否）

// チャートパネル用のオブジェクト名（UseCustomPanelLabel=true時のみ生成する）
string PanelObjectName  = "TrendRevFilterPanel";

//==================================================================
// ■ ユーティリティ
//==================================================================

// パネル用のOBJ_LABELを生成/更新する（フォントやサイズを変更したい場合に利用）
//  ・UseCustomPanelLabel=falseなら呼ばれないため、既存のComment表示と干渉しない
//  ・設定値を変更した場合にも毎回プロパティを上書きし、チャート再読み込み無しで反映できるようにする
bool EnsurePanelLabel()
{
   // 既に存在するか確認し、なければ生成する
   if(!ObjectFind(0, PanelObjectName))
   {
      if(!ObjectCreate(0, PanelObjectName, OBJ_LABEL, 0, 0, 0))
         return(false); // 何らかの理由で作成失敗
   }

   // 位置と見栄えを入力パラメータに合わせて毎回上書き（チャート設定変更にも追従）
   ObjectSetInteger(0, PanelObjectName, OBJPROP_CORNER, PanelCorner);
   ObjectSetInteger(0, PanelObjectName, OBJPROP_XDISTANCE, PanelXOffset);
   ObjectSetInteger(0, PanelObjectName, OBJPROP_YDISTANCE, PanelYOffset);
   ObjectSetInteger(0, PanelObjectName, OBJPROP_COLOR, PanelFontColor);
   ObjectSetInteger(0, PanelObjectName, OBJPROP_FONTSIZE, PanelFontSize);
   ObjectSetInteger(0, PanelObjectName, OBJPROP_SELECTABLE, false); // 誤操作防止のため選択不可
   ObjectSetInteger(0, PanelObjectName, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, PanelObjectName, OBJPROP_BACK, false);       // 前面に表示
   ObjectSetInteger(0, PanelObjectName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetString (0, PanelObjectName, OBJPROP_FONT, PanelFontName);
   return(true);
}

// 表示テキストをCommentまたはOBJ_LABELへ出力する共通関数
//  ・フォント変更が必要な場合は必ずOBJ_LABELを使う（UseCustomPanelLabel=true）
//  ・Comment()はフォント指定不可であるため、軽量表示専用とし誤解を避ける
void DisplayOverlayText(const string text)
{
   if(UseCustomPanelLabel)
   {
      // OBJ_LABELを使う場合はフォント指定を反映した上でテキストを更新する
      if(EnsurePanelLabel())
      {
         ObjectSetString(0, PanelObjectName, OBJPROP_TEXT, text);
      }
      // Commentは空にしておき、他EAと重ならないようにする
      Comment("");
   }
   else
   {
      // 従来どおり軽量なCommentを使用（フォント固定である点を明示）
      Comment(text);
   }
}

// 表示を完全に消す（CommentとOBJ_LABELの両方をクリア）
void ClearOverlay()
{
   Comment("");
   if(ObjectFind(0, PanelObjectName))
   {
      ObjectDelete(0, PanelObjectName);
   }
}

// 現在のシンボル桁数に応じた 1pips のポイント値を計算
double PipPoint()
{
   // JPYクロス想定(小数点第2位がpips)なら 0.01、その他は 0.0001 辺り
   if(_Digits>=3) return(0.01);     // 例: USDJPY(3)→ポイント0.001だがpipsは0.01
   else return(0.0001);
}

// pips換算（dir=+1/-1）: p1-p0 をpipsに
double Pips(double p0, double p1, int dir)
{
   return (p1 - p0) / PipPoint() * dir;
}

// ドンチャン(過去n本の高値/安値)の取得（shift=1固定で使用）
bool GetDonchian(double &dcHigh, double &dcLow, int period, ENUM_TIMEFRAMES tf, int shift_base=1)
{
   // 直近 period 本（確定足まで）から最高値/最安値を探す
   MqlRates rates[];
   int need = period + shift_base + 2;
   if(CopyRates(_Symbol, tf, 0, need, rates) < need) return false;

   ArraySetAsSeries(rates, true);
   int start = shift_base;
   int endi  = shift_base + period - 1;
   double hh = -DBL_MAX, ll = DBL_MAX;

   for(int i=start; i<=endi; ++i)
   {
      if(rates[i].high > hh) hh = rates[i].high;
      if(rates[i].low  < ll) ll = rates[i].low;
   }
   dcHigh = hh;
   dcLow  = ll;
   return true;
}

// 近似z-score（単純移動平均/標準偏差）
bool ZScore(double &z, ENUM_TIMEFRAMES tf, int period, int shift_base=1)
{
   MqlRates rates[];
   int need = period + shift_base + 2;
   if(CopyRates(_Symbol, tf, 0, need, rates) < need) return false;
   ArraySetAsSeries(rates, true);

   double sum=0.0, sum2=0.0;
   for(int i=shift_base; i<shift_base+period; ++i)
   {
      sum  += rates[i].close;
      sum2 += rates[i].close * rates[i].close;
   }
   double n = (double)period;
   double mean = sum / n;
   double var  = (sum2/n) - mean*mean;
   if(var < 1e-12) { z=0.0; return true; }
   double sd = MathSqrt(var);
   double c1 = rates[shift_base].close;
   z = (c1 - mean) / sd;
   return true;
}

// RSI取得
double GetRSI(ENUM_TIMEFRAMES tf, int period, int shift)
{
   double buf[];
   if(CopyBuffer(iRSI(_Symbol, tf, period, PRICE_CLOSE), 0, shift, 2, buf) != 2) return NaNValue; // 取得失敗時はNaNを返し、後続ロジックで除外する
   return(buf[1]); // shiftのバーの値（確定足基準）
}

// EMA取得
double GetEMA(ENUM_TIMEFRAMES tf, int period, int shift)
{
   double buf[];
   if(CopyBuffer(iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE), 0, shift, 2, buf) != 2) return NaNValue; // 失敗時はNaNで異常を通知
   return buf[1];
}

// ATR取得
double GetATR(ENUM_TIMEFRAMES tf, int period, int shift)
{
   double buf[];
   if(CopyBuffer(iATR(_Symbol, tf, period), 0, shift, 2, buf) != 2) return NaNValue; // 失敗時はNaNを返却
   return buf[1];
}

// ADX取得（H1）
double GetADX(ENUM_TIMEFRAMES tf, int period, int shift)
{
   double buf[];
   if(CopyBuffer(iADX(_Symbol, tf, period), 0, shift, 2, buf) != 2) return NaNValue; // 失敗時はNaNを返却
   return buf[1];
}

// MACDヒストグラム取得（M1）
double GetMACDHist(ENUM_TIMEFRAMES tf, int fast, int slow, int signal, int shift)
{
   // バッファ2=MACDヒスト（MetaTraderのiMACD仕様）
   double buf[];
   if(CopyBuffer(iMACD(_Symbol, tf, fast, slow, signal, PRICE_CLOSE), 2, shift, 2, buf) != 2) return NaNValue; // 取得失敗時のNaN返却で安全に処理を抜ける
   return buf[1];
}

// 当日VWAP簡易版（ティックボリューム使用）: 直近「当日開始バー」から確定バーまでの加重平均
bool GetDailyVWAP(double &vwap, ENUM_TIMEFRAMES tf, int shift_base=1)
{
   // 当日の0:00以降のバーを集計（ブローカー時間）
   MqlRates rates[];
   int got = CopyRates(_Symbol, tf, 0, 1440*2, rates);
   if(got <= 0) return false;
   ArraySetAsSeries(rates, true);

   datetime t = rates[shift_base].time;
   MqlDateTime md; TimeToStruct(t, md);
   md.hour=0; md.min=0; md.sec=0;
   datetime dayStart = StructToTime(md);

   // dayStart以降でshift_baseから過去方向に積み上げ
   double pv_sum=0.0, v_sum=0.0;
   for(int i=shift_base; i<got; ++i)
   {
      if(rates[i].time < dayStart) break;
      double price = rates[i].close;
      double vol   = (double)rates[i].tick_volume;
      if(vol < 1.0) vol = 1.0; // 0除算対策
      pv_sum += price * vol;
      v_sum  += vol;
   }
   if(v_sum <= 0.0) return false;
   vwap = pv_sum / v_sum;
   return true;
}

// リニア回帰のR^2簡易近似（H1）
bool GetR2(double &r2, ENUM_TIMEFRAMES tf, int period, int shift_base=1)
{
   MqlRates rates[];
   int need = period + shift_base + 2;
   if(CopyRates(_Symbol, tf, 0, need, rates) < need) return false;
   ArraySetAsSeries(rates, true);

   // y: close, x: 0..period-1
   double sumx=0,sumy=0,sumxx=0,sumxy=0,sumyy=0;
   int n=period;
   for(int i=0;i<period;++i)
   {
      double x=i;
      double y=rates[shift_base+i].close;
      sumx+=x; sumy+=y; sumxx+=x*x; sumxy+=x*y; sumyy+=y*y;
   }
   double denom = (n*sumxx - sumx*sumx);
   if(MathAbs(denom) < 1e-9){ r2=0.0; return true; }
   double a = (n*sumxy - sumx*sumy)/denom;      // 傾き
   double b = (sumy - a*sumx)/n;                // 切片

   // 決定係数 R^2
   double ss_tot=0, ss_res=0;
   double mean = sumy / n;
   for(int i=0;i<period;++i)
   {
      double x=i;
      double y=rates[shift_base+i].close;
      double yhat = a*x + b;
      ss_tot += (y-mean)*(y-mean);
      ss_res += (y-yhat)*(y-yhat);
   }
   if(ss_tot < 1e-12){ r2=0.0; return true; }
   r2 = 1.0 - ss_res/ss_tot;
   return true;
}

//==================================================================
// ■ 逆張りフィルタ・スコア（確定バー：shift=1の足に対して評価）
//    ・BUYを試みる場合は SELLの逆張りスコアでベトー判定
//    ・SELLを試みる場合は BUYの逆張りスコアでベトー判定
//==================================================================
void ReverseScores(double &revBuy, double &revSell)
{
   revBuy = 0.0;  // doubleに統一し、表示側と内部ロジックの型差異による混乱を防止
   revSell= 0.0;  // 同上（整数加点でも double で保持しておくと将来の拡張に強い）

   // 必要な値を収集（すべて shift=1＝確定バー）
   double cOpen, cHigh, cLow, cClose;
   // 静的配列ではArraySetAsSeriesが利用できないため動的配列に変更し、
   // 足方向を確定足基準（series=true）へ揃えて参照ミスを防止する
   MqlRates r[];
   if(CopyRates(_Symbol, TF_Trade, 0, 3, r) < 3) return;
   ArraySetAsSeries(r, true);
   cOpen  = r[1].open;
   cHigh  = r[1].high;
   cLow   = r[1].low;
   cClose = r[1].close;

   double atr  = GetATR(TF_Trade, ATR_Period_M1, 1);
   double ema  = GetEMA(TF_Trade, EMA_Period_M1, 1);
   double rsi  = GetRSI(TF_Trade, RSI_Period, 1);
   double vwap;
   if(!GetDailyVWAP(vwap, TF_Trade, 1)) return;

   if(atr <= 0 || MathIsValidNumber(atr)==false) return;

   // キャンドル構造
   double body  = MathAbs(cClose - cOpen);
   double upper = cHigh - MathMax(cClose, cOpen);
   double lower = MathMin(cClose, cOpen) - cLow;
@@ -338,65 +412,65 @@ void ReverseScores(int &revBuy, int &revSell)
   if(d2 >= Rev_vwap2_ATR && cClose > cOpen) revBuy += 2;
   else if(d2 >= Rev_vwap1_ATR && cClose > cOpen) revBuy += 1;

   if(d2 >= Rev_vwap2_ATR && cClose < cOpen) revSell += 2;
   else if(d2 >= Rev_vwap1_ATR && cClose < cOpen) revSell += 1;

   // 3) RSI 極端 + ローソク方向
   if(rsi <= Rev_RSI_Extreme && cClose > cOpen) revBuy += 1;
   if(rsi >= (100 - Rev_RSI_Extreme) && cClose < cOpen) revSell += 1;

   // 4) ピンバー（ヒゲ長・実体小）
   if( (lower/atr) >= Rev_Pin_WickMin_ATR && (body/atr) <= Rev_Pin_BodyMax_ATR ) revBuy += 1;
   if( (upper/atr) >= Rev_Pin_WickMin_ATR && (body/atr) <= Rev_Pin_BodyMax_ATR ) revSell+= 1;
}

//==================================================================
// ■ チャート表示更新（逆張りスコア・順張りスコアを最新確定バー基準で表示）
//    ・EntryScore / ReverseScores を再計算し、Commentで簡易パネルを表示
//    ・「基準値と現在値」を明示して、フィルタがどの程度で作動するかを視覚化
//==================================================================
void UpdateScoreOverlay()
{
   // 最新確定バー（shift=1）の情報を再評価し、画面表示用の変数に保存
   lastBuyGate  = false;
   lastSellGate = false;
   lastEntryScore = (double)EntryScore(lastBuyGate, lastSellGate); // 文脈ゲートも同時に更新（表示と内部型を統一）

   double rb=0.0, rs=0.0; // 表示・内部をdoubleで統一し、整数丸めによる情報欠落を防ぐ
   ReverseScores(rb, rs); // 逆張りスコアを取得（値が取れなかった場合は0のまま）
   lastRevBuyScore  = rb;
   lastRevSellScore = rs;

   // 表示用テキストを作成（基準値がどこにあるかも併記）
   string text = "TrendRevFilter スコア状況\n";
   text += StringFormat("EntryScore: %.1f (買い基準 +%d / 売り基準 -%d)\n", lastEntryScore, ENTRY_T, ENTRY_T);
   text += StringFormat("H1ゲート: BUY=%s / SELL=%s\n", lastBuyGate ? "ON" : "OFF", lastSellGate ? "ON" : "OFF");
   text += StringFormat("逆張りスコア: BUY方向=%.1f / SELL方向=%.1f (veto基準 %d)", lastRevBuyScore, lastRevSellScore, REV_T);

   // 入力に応じて Comment または OBJ_LABEL へ表示（フォント変更が必要ならOBJ_LABELを選択）
   DisplayOverlayText(text);
}

//==================================================================
// ■ 順張りエントリー・スコア（確定バー：shift=1）
//    H1：EMA傾き・R2・ADX で文脈ゲート
//    M1：ドンチャン位置×短期Z、バンド幅%位（簡略化：低ボラ優遇）
//        プルバック(EMAとの距離)、CLV累積 などを加点
//    ※ buyGate / sellGate は true/false の論理フラグなので、型を bool で定義して
//       コンパイラ警告や型変換エラーを防ぐ（MQL5 では参照引数の型一致が必須）。
//==================================================================
int EntryScore(bool &buyGate, bool &sellGate)
{
   buyGate  = false;
   sellGate = false;

   // ---- H1 文脈ゲート ----
   // H1 EMA傾き（直近2点差分で近似）
   double ema_h1_now  = GetEMA(TF_Context, H1_EMA_Period, 1);
   double ema_h1_prev = GetEMA(TF_Context, H1_EMA_Period, 2);
   if(!MathIsValidNumber(ema_h1_now) || !MathIsValidNumber(ema_h1_prev)) return 0;

   double slope = ema_h1_now - ema_h1_prev; // 簡易傾き
   double r2;
   if(!GetR2(r2, TF_Context, H1_R2_Period, 1)) r2 = 0.0;

   if( r2 >= R2_GATE && slope > 0 && MathAbs(slope) >= H1_Slope_Min ) buyGate = true;
   if( r2 >= R2_GATE && slope < 0 && MathAbs(slope) >= H1_Slope_Min ) sellGate= true;

   // ---- M1 近接データ（確定足）----
   // 入力値に依存する可変長サイズのため、動的配列で安全に確保（静的配列ではビルドエラーになるため）
   MqlRates rt[];
   int need = MathMax(MathMax(Donchian_Period+2, ZLong_Period+2), CLV_Sum_Period+2) + 5;
   if(CopyRates(_Symbol, TF_Trade, 0, need, rt) < need) return 0; // 必要本数取れなければ評価不能
   ArraySetAsSeries(rt, true); // シリーズ方向を反転させ、インデックスを確定足基準で扱いやすくする

   double close1 = rt[1].close;
   double open1  = rt[1].open;
   double high1  = rt[1].high;
   double low1   = rt[1].low;

   double atr1 = GetATR(TF_Trade, ATR_Period_M1, 1);
   double ema1 = GetEMA(TF_Trade, EMA_Period_M1, 1);
   if(atr1<=0 || !MathIsValidNumber(ema1)) return 0;

   // 実体/ヒゲチェック（品質）
   double body = MathAbs(close1-open1);
   double upper= high1 - MathMax(close1,open1);
   double lower= MathMin(close1,open1) - low1;
   if( (body/atr1) < RealBody_Min_ATR ){ buyGate=false; sellGate=false; }

   if(buyGate && (lower/atr1) > Wick_Max_ATR) buyGate = false;
   if(sellGate&& (upper/atr1) > Wick_Max_ATR) sellGate= false;

   // ドンチャン位置（直近終値の位置 0..1）
   double dch, dcl;
   if(!GetDonchian(dch, dcl, Donchian_Period, TF_Trade, 1)) return 0;
   double don_pos = 0.5;
   if(dch>dcl) don_pos = (close1 - dcl) / (dch - dcl);

   // 短期z
   double z_short;
   if(!ZScore(z_short, TF_Trade, ZShort_Period, 1)) z_short = 0.0;

   int score = 0;
   // ドンチャン×z の方向性
   if( don_pos>=0.70 && z_short>=0.50 ) score += 2;
   else if( don_pos>=0.55 && z_short>=0.20 ) score += 1;
   else if( don_pos<=0.30 && z_short<=-0.20) score -= 1;
   else if( don_pos<=0.20 && z_short<=-0.50) score -= 2;

   // バンド幅%位（簡略：標準偏差/平均で低ボラ優遇）…重くなるので簡易化
   // → ここでは「ATR/価格」による簡易ボラ判定で代替（低ボラ優遇）
   double vol_ratio = atr1 / MathMax(1.0, close1);
   if(vol_ratio < 0.0006) score += 2;
   else if(vol_ratio < 0.0010) score += 1;

   // プルバック（EMAとの距離）
   double pb = (ema1 - close1)/atr1; // 上昇トレンド戻り
   double ps = (close1 - ema1)/atr1; // 下降トレンド戻り
   if( pb >= Pullback_Min_ATR && pb <= Pullback_Max_ATR ) score += 1;
   if( ps >= Pullback_Min_ATR && ps <= Pullback_Max_ATR ) score -= 1;

   // CLV累積（直近CLVの合計）
   double clv_sum = 0.0;
   int cnum = 0;
   for(int i=1; i<=CLV_Sum_Period; ++i)
   {
      double h = rt[i].high, l = rt[i].low, c = rt[i].close;
      double denom = MathMax(1e-6, h - l);
      double clv  = ((c - l) - (h - c)) / denom;
      clv_sum += clv;
      ++cnum;
   }
   if(cnum>0)
   {
      if(clv_sum >= 1.2) score += 1;
      if(clv_sum <= -1.2) score -= 1;
   }

   return score;
}

//==================================================================
// ■ EXIT スコア（確定バー：shift=1）
//    ・ADXで動的トレーリング圧（簡易）
//    ・RSI/MACDヒスト/連続性（streakは簡易化：連続同符号本数を使わず符号のみ）
//    ・MFE/MAEと経過本数で評価
//    ・長期z + VWAP距離で張り付き離脱
//==================================================================
int ExitScore(int dir)
{
   // 取得
   double atr1 = GetATR(TF_Trade, ATR_Period_M1, 1);
   if(atr1<=0) return 0;

   double adx_h1 = GetADX(TF_Context, H1_ADX_Period, 1);
   double rsi1   = GetRSI(TF_Trade, RSI_Period, 1);
   double macdh1 = GetMACDHist(TF_Trade, MACD_Fast, MACD_Slow, MACD_Signal, 1);

   // ZLong_Periodに応じて本数が変わるため動的配列で取得（静的配列では定数式が必要なためエラーとなる）
   MqlRates r[];
   int need = ZLong_Period + 5;
   if(CopyRates(_Symbol, TF_Trade, 0, need, r) < need) return 0; // データ不足時は即終了
   ArraySetAsSeries(r, true); // インデックスを現在足から遡る形に統一
   double close1 = r[1].close;
   double open1  = r[1].open;

   // 動的トレーリング圧（基準ラインにどれだけ近いかをスコア化）
   double k = 3.3;
   if(adx_h1 >= 25) k = 3.7;
   else if(adx_h1 >= 20) k = 3.5;

   // 簡易トレール基準（※実際のストップ移動は行わず、スコア付与のみ）
   double trail_line = posEntryPrice - dir * (k * atr1);
   double dist = MathAbs(close1 - trail_line) / atr1;
   int s=0;
   if(dist < 0.20) s += 2;
   else if(dist < 0.35) s += 1;

   // モメンタム弱化
   if(dir==+1)
   {
      if(rsi1 < 45) s += 2;
      else if(rsi1 < 50 || macdh1 < 0) s += 1;
   }
   else
   {
      if(rsi1 > 55) s += 2;
      else if(rsi1 > 50 || macdh1 > 0) s += 1;
   }

   // MFE/MAE と 経過本数
   double ratio = (posMAE!=0.0) ? (posMFE / MathAbs(posMAE)) : 0.0;
   if(posBars >= 300 && ratio < 0.6) s += 2;
   else if(posBars >= 120 && ratio < 0.8) s += 1;

   // 長期z + VWAP距離
   double zlong;
   if(!ZScore(zlong, TF_Trade, ZLong_Period, 1)) zlong = 0.0;
   double vwap;
   if(!GetDailyVWAP(vwap, TF_Trade, 1)) vwap = close1;
   double d2 = MathAbs(close1 - vwap) / atr1;

   if(dir==+1)
   {
      if(zlong >= 1.8 && d2 >= VWAP_Exit_ATR) s += 2;
      else if(zlong >= 1.2) s += 1;
   }
   else
   {
      if(zlong <= -1.8 && d2 >= VWAP_Exit_ATR) s += 2;
      else if(zlong <= -1.2) s += 1;
   }

   // 長時間保有
   if(posBars >= TimeScoreBars) s += 2;

   return s;
}

//==================================================================
// ■ エントリー実行（逆張りフィルタで veto したら入らない）
//==================================================================
void TryEntry()
{
   // ゲート & スコア
   // 参照渡しを行うため bool で明示し、文脈ゲートが ON/OFF かを正確に保持する
   bool buyGate=false, sellGate=false;
   double es = (double)EntryScore(buyGate, sellGate); // doubleに保持して表示と内部判定の型を一致させる
   if(!hasPosition)
   {
      // 逆張りフィルタの評価（確定バーに対して）
      double revBuy, revSell; // 表示側と同じ double で保持し、型差異による丸めを防止
      ReverseScores(revBuy, revSell);

      // BUY候補
      if(InpLongAllowed && buyGate && es >= ENTRY_T)
      {
         // SELL方向の逆張りスコアが閾値以上なら veto
         if(revSell >= REV_T)
         {
            if(Log_Entry) Print("[VETO] BUY blocked by reverse-sell score=", revSell, " (>= ", REV_T, "), es=", es);
         }
         else
         {
            // 発注（現在バーの始値近辺＝OnTick中の成行、スリッページで吸収）
            trade.SetExpertMagicNumber(InpMagic);
            trade.SetDeviationInPoints(InpSlippagePoints);
            if(trade.Buy(InpLots, _Symbol))
            {
               hasPosition   = true;
               posDir        = +1;
               posTicket     = (long)trade.ResultOrder();
               posEntryPrice = trade.ResultPrice();
               posBars       = 0;
               posMFE        = 0.0;
               posMAE        = 0.0;
               if(Log_Entry) Print("[ENTRY] BUY es=", es, " revSell=", revSell, " price=", posEntryPrice);
@@ -689,51 +763,52 @@ int OnInit()
   // pips基準の内部定義
   PointPips   = PipPoint();
   // ここでは固定スプレッド想定（必要に応じてSymbolInfoIntegerで取得可）
   SpreadPips  = 0.1;

   // NaNValue を実行時に生成（0除算を避け、MathSqrt(-1.0)で確実にNaNを得る）
   // 以降、インジケータ取得失敗などの異常値返却で統一的に利用する
   NaNValue = MathSqrt(-1.0);

   // 最低限の履歴を確保（エラー抑止）
   MqlRates tmp1[], tmp2[];
   if(CopyRates(_Symbol, TF_Trade, 0, LookbackBars_M1, tmp1) <= 0)
      return(INIT_FAILED);
   if(CopyRates(_Symbol, TF_Context, 0, LookbackBars_H1, tmp2) <= 0)
      return(INIT_FAILED);

   if(ArraySize(tmp1) > 0) last_bar_time = tmp1[0].time;

   Print("TrendRevFilter initialized. Magic=", InpMagic);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("TrendRevFilter deinit. reason=", reason);
   // Comment/OBJ_LABEL の両方を明示的に消し、別EAへ表示が残らないようにする
   ClearOverlay();
}

void OnTick()
{
   // ティック更新取得（未使用でも残しておく）
   if(!SymbolInfoTick(_Symbol, last_tick)) return;

   // 新バー判定（取引時間足＝M1）
   // 静的確保では警告が出るため、動的配列で最新3本を取得し系列方向を揃える
   MqlRates r[];
   if(CopyRates(_Symbol, TF_Trade, 0, 3, r) < 3) return;
   ArraySetAsSeries(r, true);

   if(r[0].time != last_bar_time)
   {
      // 新バーに切替
      last_bar_time = r[0].time;

      // ポジション情報更新（MFE/MAE、経過本数）
      if(hasPosition)
      {
         double prevClose = r[1].close;
         double pf = Pips(posEntryPrice, prevClose, posDir);
         if(pf > posMFE) posMFE = pf;
         if(pf < posMAE) posMAE = pf;
         posBars++;
      }

      // チャートオーバーレイ（スコアと基準値の可視化）を更新
      //  ※逆張りフィルタが効いているかを視覚的に把握できるように、
      //    「EntryScore」「逆張りスコア」「基準値」をまとめて表示する
      UpdateScoreOverlay();

      // まず決済判定
      TryExit();

      // その後エントリー判定（ポジがないとき）
      if(InpOnePositionOnly)
      {
         // 同時1ポジ制限：現在ポジ確認
         if(PositionsTotal() == 0 && !hasPosition)
         {
            TryEntry();
         }
         else
         {
            // 口座に既存ポジがあるがhasPosition=falseなら同期
            if(!hasPosition)
            {
               // 他EA/手動のポジがある可能性 → 同期（シンボル/マジック一致のみ管理）
               for(int i=0;i<PositionsTotal();++i)
               {
                  ulong ticket = PositionGetTicket(i);
                  if(PositionSelectByTicket(ticket))
                  {
                     if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
                        PositionGetInteger(POSITION_MAGIC)==(long)InpMagic)
                     {
                        hasPosition   = true;
                        posDir        = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? +1 : -1;
                        posTicket     = (long)ticket;
                        posEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                        posBars       = 0;
                        posMFE        = 0.0;
                        posMAE        = 0.0;
                        break;
                     }
                  }
               }
            }
         }
      }
      else
      {
         // 同時複数許可モード（本EAの設計上は非推奨だが残す）
         TryEntry();
      }
   }
}
