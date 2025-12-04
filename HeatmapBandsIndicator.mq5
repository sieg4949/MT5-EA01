//+------------------------------------------------------------------+
//|                                     HeatmapBandsIndicator.mq5    |
//|                             ヒートマップ帯とシグナル矢印描画用    |
//|                              (EA仕様のヒートマップ計算を流用)    |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

// インジケーターはメインチャート上に描画し、バッファは矢印のみ使用
#property indicator_chart_window
// バンド塗りつぶし用のプロットを最大5本まで用意（上下2バッファ×5本＋矢印2本＝12バッファ）
#property indicator_buffers 12
// プロットは「買い矢印」「売り矢印」「バンド1〜5」の合計7本
#property indicator_plots   7

// 買い矢印プロット設定
#property indicator_label1  "HeatmapBuy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// 売り矢印プロット設定
#property indicator_label2  "HeatmapSell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

// バンド塗りつぶし用プロット（最大5本分を事前宣言）
#property indicator_label3  "Band1"
#property indicator_type3   DRAW_FILLING
#property indicator_color3  clrOrange,clrOrange

#property indicator_label4  "Band2"
#property indicator_type4   DRAW_FILLING
#property indicator_color4  clrOrange,clrOrange

#property indicator_label5  "Band3"
#property indicator_type5   DRAW_FILLING
#property indicator_color5  clrOrange,clrOrange

#property indicator_label6  "Band4"
#property indicator_type6   DRAW_FILLING
#property indicator_color6  clrOrange,clrOrange

#property indicator_label7  "Band5"
#property indicator_type7   DRAW_FILLING
#property indicator_color7  clrOrange,clrOrange

//+------------------------------------------------------------------+
// 入力パラメータ（EAと同じ命名を極力維持し、後から照合しやすくする）
//+------------------------------------------------------------------+
input ENUM_TIMEFRAMES TF_Context     = PERIOD_H1;   // 文脈（H1想定）
input ENUM_TIMEFRAMES TF_Trigger     = PERIOD_M5;   // 執行（M5想定）
input int            ATR_H1_Period   = 14;          // ATR計算期間（H1）
input int            HM_Lookback_M5  = 120;         // ヒートマップ対象M5本数
input double         HM_Bucket_Pips  = 2.0;         // バケット幅（pips）
input int            HM_Weight_A     = 30;          // スイング極値の重み
input int            HM_Weight_B     = 20;          // 前日高安・当日始値の重み
input int            HM_Weight_D     = 50;          // VWAPの重み
input double         HM_Score_Threshold = 58.0;      // 採用スコア閾値
input int            DisplayTopBands = 5;           // 表示する上位帯の数
input bool           ShowBands       = true;        // 帯を描画するか
input bool           ShowSignalArrows= true;        // シグナル矢印を描画するか
input double         EnterTol_H1ATR  = 0.45;        // 価格と帯の許容距離（ATR係数）
input color          BandColor       = clrOrange;   // 帯の基本色
input color          BandFillColor   = clrOrange;   // 帯の塗りつぶし色
input int            BandOpacity     = 25;          // 帯の透過度（0-255）

//+------------------------------------------------------------------+
//| 内部構造体・グローバル                                           |
//+------------------------------------------------------------------+
struct BandInfo
  {
   double level;   // バケット中心価格
   double score;   // 0-100に正規化されたスコア
  };

// 矢印描画用バッファ
double g_buyBuffer[];
double g_sellBuffer[];

// バンド塗りつぶし用バッファ（最大5本分の上端・下端を保持）
// MQL5では「動的配列の配列」への直接インデックスアクセスがサポートされないため、
// スロットごとに個別の配列を定義し、ヘルパー関数で切り替える方式を採用する。
// こうすることでSetIndexBufferやArraySetAsSeriesへの渡し先が明確になり、
// コンパイラの"invalid array access"エラーを確実に回避できる。
const int MAX_TOP_BANDS = 5;
double g_bandUpper0[];
double g_bandLower0[];
double g_bandUpper1[];
double g_bandLower1[];
double g_bandUpper2[];
double g_bandLower2[];
double g_bandUpper3[];
double g_bandLower3[];
double g_bandUpper4[];
double g_bandLower4[];

// ヒートマップ計算結果キャッシュ
BandInfo g_bands[];
datetime g_lastH1Time = 0;   // 直近のH1確定足時間

// ATRハンドル（H1）
int g_atrH1Handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| 前方宣言                                                         |
//+------------------------------------------------------------------+
bool BuildHeatmap();
bool LoadM5Window(int count, MqlRates &out[]);
void VoteSwings(const MqlRates &m5[], int len, double lo, double bucket, double &scoreA[], int bucketCount);
void VotePrevDayLevels(double lo, double bucket, double &scoreB[], int bucketCount);
void VoteVWAP(const MqlRates &m5[], int len, const MqlRates &h1[], int h1len, double lo, double bucket, double &scoreD[], int bucketCount);
void DrawBands(const datetime &time[], int bars);
void ClearBandObjects(int keepCount);
void UpdateArrows(const double &close[], int rates_total, int prev_calculated);
void ResetBandSlotBuffers(const int slot, const int bars);
void FillBandSlot(const int slot, const int bars, const double top, const double bottom);
void ApplyBandPlotColors();

//+------------------------------------------------------------------+
//| 初期化                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 矢印バッファをインジケータに紐付け
   SetIndexBuffer(0, g_buyBuffer, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_ARROW, 234); // ↑矢印（Wingdings）

   SetIndexBuffer(1, g_sellBuffer, INDICATOR_DATA);
   PlotIndexSetInteger(1, PLOT_ARROW, 233); // ↓矢印（Wingdings）

   // バッファは基本非表示（必要時のみ値をセット）
   ArrayInitialize(g_buyBuffer, EMPTY_VALUE);
   ArrayInitialize(g_sellBuffer, EMPTY_VALUE);

   // バンド塗りつぶし用のバッファを全プロット分紐付け
   // （DRAW_FILLINGは上下2本のバッファが必要なため、上端・下端をセットで登録する）
   for(int i=0;i<MAX_TOP_BANDS;i++)
     {
      int upperIndex = 2 + 2*i; // バッファ番号（矢印2本の次から順に使用）
      int lowerIndex = 3 + 2*i;

      // スロットに紐づく実バッファを取得し、インジケータに接続
      // MQL5では参照変数を未初期化で宣言できないため、各caseで配列を束縛する
      switch(i)
        {
         case 0:
            SetIndexBuffer(upperIndex, g_bandUpper0, INDICATOR_DATA);
            SetIndexBuffer(lowerIndex, g_bandLower0, INDICATOR_DATA);
            break;
         case 1:
            SetIndexBuffer(upperIndex, g_bandUpper1, INDICATOR_DATA);
            SetIndexBuffer(lowerIndex, g_bandLower1, INDICATOR_DATA);
            break;
         case 2:
            SetIndexBuffer(upperIndex, g_bandUpper2, INDICATOR_DATA);
            SetIndexBuffer(lowerIndex, g_bandLower2, INDICATOR_DATA);
            break;
         case 3:
            SetIndexBuffer(upperIndex, g_bandUpper3, INDICATOR_DATA);
            SetIndexBuffer(lowerIndex, g_bandLower3, INDICATOR_DATA);
            break;
         default:
            SetIndexBuffer(upperIndex, g_bandUpper4, INDICATOR_DATA);
            SetIndexBuffer(lowerIndex, g_bandLower4, INDICATOR_DATA);
            break;
        }

      // プロット番号は「買い=0」「売り=1」に続くi番目の塗りつぶしなので2+iとなる
      int plotIndex = 2 + i;

      // 塗りつぶしの空値を明示し、余計な線が出ないようにする
      PlotIndexSetDouble(plotIndex, PLOT_EMPTY_VALUE, EMPTY_VALUE);
    }

   // 塗りつぶし色や線幅などのプロパティは、DRAW_FILLINGの仕様に沿ってまとめて設定する
   // （参考：MetaQuotes公式のDRAW_FILLING.mq5サンプルと同様に、PLOT_LINE_COLORで上下別色を指定可能）
   ApplyBandPlotColors();

   // ATRハンドル作成（H1の確定足を基準）
   g_atrH1Handle = iATR(_Symbol, TF_Context, ATR_H1_Period);
   if(g_atrH1Handle==INVALID_HANDLE)
     {
      Print("ATRハンドルの作成に失敗しました");
      return(INIT_FAILED);
     }

   // 旧バージョンの矩形オブジェクトがチャートに残っている可能性があるため事前に全削除
   ClearBandObjects(0);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| 解放処理：生成した矩形オブジェクトを一括削除                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ClearBandObjects(0);
  }

//+------------------------------------------------------------------+
//| メイン計算                                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   // H1の確定足時間を確認し、変化があればヒートマップを再構築
   datetime h1Time = iTime(_Symbol, TF_Context, 1);
   if(h1Time!=0 && h1Time!=g_lastH1Time)
     {
      if(BuildHeatmap())
         g_lastH1Time = h1Time;
     }

   // 帯の描画
   if(ShowBands)
      DrawBands(time, rates_total);
   else
     {
      // オフ時は塗りつぶしバッファを空値でリセットし、旧矩形オブジェクトも掃除
      for(int slot=0; slot<MAX_TOP_BANDS; slot++)
        {
         // スロットごとに安全に初期化（参照未初期化問題を避けるため専用ヘルパーを使用）
         ResetBandSlotBuffers(slot, rates_total);
        }
      ClearBandObjects(0);
     }

   // 矢印更新
   if(ShowSignalArrows)
      UpdateArrows(close, rates_total, prev_calculated);
   else
     {
      // オフ時はバッファをクリア
      ArraySetAsSeries(g_buyBuffer, true);
      ArraySetAsSeries(g_sellBuffer, true);
      for(int i=prev_calculated; i<rates_total; i++)
        {
         g_buyBuffer[i] = EMPTY_VALUE;
         g_sellBuffer[i] = EMPTY_VALUE;
        }
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| ヒートマップ構築（EA仕様のA/B/D投票を踏襲）                       |
//+------------------------------------------------------------------+
bool BuildHeatmap()
  {
   // M5データを取得し、指定本数に満たない場合は処理を中断
   MqlRates m5[];
   if(!LoadM5Window(HM_Lookback_M5+5, m5))
      return(false);
   int len = ArraySize(m5);
   if(len<HM_Lookback_M5/2)
      return(false);

   // 高値・安値からレンジとバケット幅を算出
   double highest = m5[0].high;
   double lowest  = m5[0].low;
   for(int i=1;i<HM_Lookback_M5 && i<len;i++)
     {
      if(m5[i].high>highest) highest=m5[i].high;
      if(m5[i].low <lowest)  lowest =m5[i].low;
     }
   double range = highest - lowest;
   double bucket = HM_Bucket_Pips * _Point; // pips指定をポイントに変換
   if(bucket<=0.0 || range<=0.0)
      return(false);

   int bucketCount = (int)MathCeil(range/bucket)+1;
   if(bucketCount<=0 || bucketCount>500)
      return(false); // 過剰計算の防止

   // 投票用配列を初期化
   double scoreA[]; ArrayResize(scoreA, bucketCount); ArrayInitialize(scoreA, 0.0);
   double scoreB[]; ArrayResize(scoreB, bucketCount); ArrayInitialize(scoreB, 0.0);
   double scoreD[]; ArrayResize(scoreD, bucketCount); ArrayInitialize(scoreD, 0.0);

   // H1データ（VWAP加重用）
   MqlRates h1[];
   CopyRates(_Symbol, TF_Context, 1, 200, h1); // 必要数を多めに取得
   ArraySetAsSeries(h1, true);

   // 仕様に沿ったスコア投票
   VoteSwings(m5, len, lowest, bucket, scoreA, bucketCount);
   VotePrevDayLevels(lowest, bucket, scoreB, bucketCount);
   VoteVWAP(m5, len, h1, ArraySize(h1), lowest, bucket, scoreD, bucketCount);

   // スコア合成と0-100正規化
   double scores[]; ArrayResize(scores, bucketCount);
   double rawMax = 0.0;
   for(int i=0;i<bucketCount;i++)
     {
      scores[i] = HM_Weight_A*scoreA[i] + HM_Weight_B*scoreB[i] + HM_Weight_D*scoreD[i];
      if(scores[i]>rawMax) rawMax=scores[i];
     }
   if(rawMax<=0.0)
      return(false);

   for(int i=0;i<bucketCount;i++)
      scores[i] = (scores[i]/rawMax)*100.0;

   // バケット中心価格配列を作成
   double buckets[]; ArrayResize(buckets, bucketCount);
   for(int i=0;i<bucketCount;i++)
      buckets[i] = lowest + bucket*i;

   // 既存配列をクリアし、スコア順に格納
   ArrayResize(g_bands, 0);
   for(int i=0;i<bucketCount;i++)
     {
      BandInfo info; info.level=buckets[i]; info.score=scores[i];
      int pos = ArraySize(g_bands);
      ArrayResize(g_bands, pos+1);
      g_bands[pos] = info;
     }

   // 単純なバブルソートでスコア降順に並べ替え（帯数が少ないため速度影響は軽微）
   int total = ArraySize(g_bands);
   for(int i=0;i<total-1;i++)
     {
      for(int j=i+1;j<total;j++)
        {
         if(g_bands[i].score < g_bands[j].score)
           {
            BandInfo tmp = g_bands[i];
            g_bands[i] = g_bands[j];
            g_bands[j] = tmp;
           }
        }
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| M5の価格データを指定本数取得                                     |
//+------------------------------------------------------------------+
bool LoadM5Window(int count, MqlRates &out[])
  {
   if(ArraySize(out)!=count)
      ArrayResize(out, count);
   if(CopyRates(_Symbol, TF_Trigger, 1, count, out) < count-1)
      return(false);
   ArraySetAsSeries(out, true);
   return(true);
  }

//+------------------------------------------------------------------+
//| スイング高安の投票：左右固定k=3で極値を抽出                      |
//+------------------------------------------------------------------+
void VoteSwings(const MqlRates &m5[], int len, double lo, double bucket, double &scoreA[], int bucketCount)
  {
   int k = 3;
   for(int i=k; i<len-k; i++)
     {
      double h = m5[i].high;
      double l = m5[i].low;
      bool isHigh = true;
      bool isLow  = true;
      for(int j=1; j<=k; j++)
        {
         if(m5[i-j].high > h || m5[i+j].high > h) isHigh=false;
         if(m5[i-j].low  < l || m5[i+j].low  < l) isLow=false;
        }
      if(isHigh)
        {
         int idx = (int)MathMin(MathMax(MathFloor((h - lo)/bucket),0), bucketCount-1);
         scoreA[idx] += 1.0;
        }
      if(isLow)
        {
         int idx = (int)MathMin(MathMax(MathFloor((l - lo)/bucket),0), bucketCount-1);
         scoreA[idx] += 1.0;
        }
     }
  }

//+------------------------------------------------------------------+
//| 前日高値/安値・当日始値からの投票                                 |
//+------------------------------------------------------------------+
void VotePrevDayLevels(double lo, double bucket, double &scoreB[], int bucketCount)
  {
   double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow  = iLow(_Symbol, PERIOD_D1, 1);
   double todayOpen = iOpen(_Symbol, PERIOD_D1, 0);

   double levels[3] = {prevHigh, prevLow, todayOpen};
   for(int i=0;i<3;i++)
     {
      double lv = levels[i];
      if(lv==0.0 || lv==EMPTY_VALUE)
         continue;
      int idx = (int)MathMin(MathMax(MathFloor((lv - lo)/bucket),0), bucketCount-1);
      scoreB[idx] += 1.0;
     }
  }

//+------------------------------------------------------------------+
//| VWAP関連の投票（日内VWAP＋H1累積VWAP）                           |
//+------------------------------------------------------------------+
void VoteVWAP(const MqlRates &m5[], int len, const MqlRates &h1[], int h1len, double lo, double bucket, double &scoreD[], int bucketCount)
  {
   double cumPV=0.0, cumV=0.0;
   datetime today = (m5[1].time/86400)*86400; // shift=1が属する日を判定
   for(int i=len-1; i>=1; i--)
     {
      datetime d = (m5[i].time/86400)*86400;
      if(d!=today) break;
      double tp = (m5[i].high + m5[i].low + m5[i].close)/3.0;
      double vol = (m5[i].tick_volume>0)?(double)m5[i].tick_volume:1.0;
      cumPV += tp*vol;
      cumV  += vol;
     }
   if(cumV>0.0)
     {
      double vwapD = cumPV/cumV;
      int idx = (int)MathMin(MathMax(MathFloor((vwapD - lo)/bucket),0), bucketCount-1);
      scoreD[idx] += 1.0;
     }

   // H1累積VWAP（直近確定分まで累積）
   double cumPVH1=0.0, cumVH1=0.0;
   for(int i=h1len-1;i>=1;i--)
     {
      double tp = (h1[i].high + h1[i].low + h1[i].close)/3.0;
      double vol = (h1[i].tick_volume>0)?(double)h1[i].tick_volume:1.0;
      cumPVH1 += tp*vol;
      cumVH1  += vol;
     }
   if(cumVH1>0.0)
     {
      double vwapH1 = cumPVH1/cumVH1;
      int idx = (int)MathMin(MathMax(MathFloor((vwapH1 - lo)/bucket),0), bucketCount-1);
      scoreD[idx] += 1.0;
     }
  }

//+------------------------------------------------------------------+
//| 帯をDRAW_FILLINGプロットで描画                                   |
//+------------------------------------------------------------------+
void DrawBands(const datetime &time[], int bars)
  {
   // 念のため毎回プロットプロパティを最新の入力値で反映し、
   // DRAW_FILLINGが想定した色・幅で表示されるようにする
   ApplyBandPlotColors();

   // まずすべてのバンドプロットを空値で初期化してから必要分だけ上書きする。
   // 空値で塗りつぶしを消去しないと、古い帯が残留して誤解を招くため必須。
   for(int slot=0; slot<MAX_TOP_BANDS; slot++)
     {
      // スロットの実配列を取得して初期化（未初期化参照を避けるため専用ヘルパー化）
      ResetBandSlotBuffers(slot, bars);
     }

   int total = ArraySize(g_bands);
   if(total==0)
     {
      ClearBandObjects(0); // 旧矩形オブジェクトの残骸を念のため削除
      return;
     }

   double bucket = HM_Bucket_Pips * _Point;

   // 表示する帯の最大数を、プロット数の上限(MAX_TOP_BANDS)と入力の最小値で決定
   int maxSlots = (DisplayTopBands<MAX_TOP_BANDS)?DisplayTopBands:MAX_TOP_BANDS;

   // スコア上位から順に塗りつぶしバッファへ書き込み
   int drawn=0;
   for(int i=0; i<total && drawn<maxSlots; i++)
     {
      if(g_bands[i].score < HM_Score_Threshold)
         continue; // 閾値未満の帯は描画しない

      double top = g_bands[i].level + bucket/2.0;
      double bottom = g_bands[i].level - bucket/2.0;

      // DRAW_FILLINGは「上端バッファ > 下端バッファ」で塗りつぶしが機能するため、
      // 上下を明示的にセットした上で全バーに値を適用する。
      FillBandSlot(drawn, bars, top, bottom);

      drawn++;
    }

   // 不要な矩形オブジェクトが残っている場合のみ掃除（互換目的）
   ClearBandObjects(0);
  }

//+------------------------------------------------------------------+
//| 不要な帯オブジェクトの削除（旧矩形描画の後片付け用）             |
//+------------------------------------------------------------------+
void ClearBandObjects(int keepCount)
  {
   // keepCount件までは温存し、それ以外の命名規則オブジェクトを削除
   for(int idx=keepCount; idx<20; idx++)
     {
      string name = StringFormat("HM_BAND_%d", idx);
      if(ObjectFind(0, name) != -1)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//| シグナル矢印を更新                                               |
//+------------------------------------------------------------------+
void UpdateArrows(const double &close[], int rates_total, int prev_calculated)
  {
   ArraySetAsSeries(g_buyBuffer, true);
   ArraySetAsSeries(g_sellBuffer, true);

   // 最新のATR(H1)を取得（許容距離の計算に使用）
   double atrBuf[];
   ArrayResize(atrBuf, 2);
   if(CopyBuffer(g_atrH1Handle, 0, 1, 2, atrBuf) < 1)
      return;
   ArraySetAsSeries(atrBuf, true);
   double atr = atrBuf[1];
   if(atr<=0.0)
      return;

   // 初回描画時は全バーを走査、それ以降は追加分のみ
   int start = (prev_calculated==0) ? 1 : prev_calculated-1;
   for(int i=start; i<rates_total; i++)
     {
      g_buyBuffer[i] = EMPTY_VALUE;
      g_sellBuffer[i] = EMPTY_VALUE;

      // 確定足のみ（shift=1以降）を対象にするため、末尾バーはスキップ
      if(i==0)
         continue;

      // もっとも近い帯を探索
      double price = close[i];
      double nearest = 0.0;
      double score = 0.0;
      bool found=false;
      double minDist = 0.0;
      for(int b=0; b<ArraySize(g_bands); b++)
        {
         if(g_bands[b].score < HM_Score_Threshold)
            continue;
         double dist = MathAbs(price - g_bands[b].level);
         if(!found || dist < minDist || (dist==minDist && g_bands[b].score>score))
           {
            found=true;
            minDist=dist;
            nearest=g_bands[b].level;
            score=g_bands[b].score;
           }
        }
      if(!found)
         continue;

      // ATR×係数以内に価格が存在するかをチェック
      if(minDist <= EnterTol_H1ATR * atr)
        {
         if(price < nearest)
            g_buyBuffer[i] = price;   // 帯より下にいる＝買い候補
         else if(price > nearest)
            g_sellBuffer[i] = price;  // 帯より上にいる＝売り候補
        }
    }
  }
//+------------------------------------------------------------------+
//| バンドスロットのバッファを安全に初期化                          |
//+------------------------------------------------------------------+
void ResetBandSlotBuffers(const int slot, const int bars)
  {
   // slotごとに実体をswitchで束縛し、未初期化参照エラーを防ぐ
   switch(slot)
     {
      case 0:
        {
         // 参照の束縛はコンパイラ制約で使用できないため、配列名を直接指定して初期化する
         ArraySetAsSeries(g_bandUpper0, true);
         ArraySetAsSeries(g_bandLower0, true);
         ArrayResize(g_bandUpper0, bars);
         ArrayResize(g_bandLower0, bars);
         for(int i=0;i<bars;i++) { g_bandUpper0[i]=EMPTY_VALUE; g_bandLower0[i]=EMPTY_VALUE; }
        }
        break;
      case 1:
        {
         ArraySetAsSeries(g_bandUpper1, true);
         ArraySetAsSeries(g_bandLower1, true);
         ArrayResize(g_bandUpper1, bars);
         ArrayResize(g_bandLower1, bars);
         for(int i=0;i<bars;i++) { g_bandUpper1[i]=EMPTY_VALUE; g_bandLower1[i]=EMPTY_VALUE; }
        }
        break;
      case 2:
        {
         ArraySetAsSeries(g_bandUpper2, true);
         ArraySetAsSeries(g_bandLower2, true);
         ArrayResize(g_bandUpper2, bars);
         ArrayResize(g_bandLower2, bars);
         for(int i=0;i<bars;i++) { g_bandUpper2[i]=EMPTY_VALUE; g_bandLower2[i]=EMPTY_VALUE; }
        }
        break;
      case 3:
        {
         ArraySetAsSeries(g_bandUpper3, true);
         ArraySetAsSeries(g_bandLower3, true);
         ArrayResize(g_bandUpper3, bars);
         ArrayResize(g_bandLower3, bars);
         for(int i=0;i<bars;i++) { g_bandUpper3[i]=EMPTY_VALUE; g_bandLower3[i]=EMPTY_VALUE; }
        }
        break;
      default:
        {
         ArraySetAsSeries(g_bandUpper4, true);
         ArraySetAsSeries(g_bandLower4, true);
         ArrayResize(g_bandUpper4, bars);
         ArrayResize(g_bandLower4, bars);
         for(int i=0;i<bars;i++) { g_bandUpper4[i]=EMPTY_VALUE; g_bandLower4[i]=EMPTY_VALUE; }
        }
        break;
     }
  }
//+------------------------------------------------------------------+
//| 指定スロットに上下値を一括セット                                 |
//+------------------------------------------------------------------+
void FillBandSlot(const int slot, const int bars, const double top, const double bottom)
  {
   // DRAW_FILLINGが上>下で動作することを前提に、全バーへ同値を書き込み
   switch(slot)
     {
      case 0:
        {
         // 参照ではなく直接配列へ代入することでコンパイルエラーを回避
         for(int bar=0; bar<bars; bar++) { g_bandUpper0[bar]=top; g_bandLower0[bar]=bottom; }
        }
        break;
      case 1:
        {
         for(int bar=0; bar<bars; bar++) { g_bandUpper1[bar]=top; g_bandLower1[bar]=bottom; }
        }
        break;
      case 2:
        {
         for(int bar=0; bar<bars; bar++) { g_bandUpper2[bar]=top; g_bandLower2[bar]=bottom; }
        }
        break;
      case 3:
        {
         for(int bar=0; bar<bars; bar++) { g_bandUpper3[bar]=top; g_bandLower3[bar]=bottom; }
        }
        break;
      default:
        {
        for(int bar=0; bar<bars; bar++) { g_bandUpper4[bar]=top; g_bandLower4[bar]=bottom; }
       }
       break;
     }
  }

//+------------------------------------------------------------------+
//| DRAW_FILLING用の色や幅を入力パラメータから反映                  |
//+------------------------------------------------------------------+
void ApplyBandPlotColors()
  {
   // BandOpacityを0-255に制限し、ColorToARGBで透過付き色を生成する
   // DRAW_FILLING.mq5サンプルと同様、PLOT_LINE_COLORに上下2色を設定
   int alphaClamped = (int)MathMin(MathMax(BandOpacity, 0), 255);
   uchar alphaUChar = (uchar)alphaClamped;
   color fillColorWithAlpha = (color)ColorToARGB(BandFillColor, alphaUChar);

   for(int slot=0; slot<MAX_TOP_BANDS; slot++)
     {
      int plotIndex = 2 + slot; // 塗りつぶしプロット番号（買い・売りの次）

      // 上側が下より高い領域と逆の場合の両方に同一色を適用
      PlotIndexSetInteger(plotIndex, PLOT_LINE_COLOR, 0, fillColorWithAlpha);
      PlotIndexSetInteger(plotIndex, PLOT_LINE_COLOR, 1, fillColorWithAlpha);

      // 線幅は1に固定し、塗りつぶしだけを視認させる（線を太くすると縁取りが強調される）
      PlotIndexSetInteger(plotIndex, PLOT_LINE_WIDTH, 0, 1);
      PlotIndexSetInteger(plotIndex, PLOT_LINE_WIDTH, 1, 1);
     }
  }