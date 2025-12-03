//+------------------------------------------------------------------+
//|                                           HeatmapWindowTrader.mq5|
//|                              Heatmap窓 × B優先EXIT（構造緩和版）EA |
//|                                 仕様書: EA_prompt_B_relaxed.txt  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| インクルード：注文操作はCTradeのみ使用                          |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| 入力パラメータ（仕様書そのままの名称・デフォルト）              |
//+------------------------------------------------------------------+
input double   Risk_Percent             = 1.0;      // 1トレードの証拠金％（ロット算出に使用）
input double   Lots_Min                 = 0.01;
input double   Lots_Max                 = 10.0;
input int      Magic                    = 260915;
input ENUM_TIMEFRAMES TF_Context        = PERIOD_H1;   // 文脈＝H1
input ENUM_TIMEFRAMES TF_Trigger        = PERIOD_M5;   // 執行＝M5
input int      H1_Reg_Span              = 48;          // 回帰に使う本数（H1）
input double   H1_Reg_StdCoeff          = 0.002;       // しきい値 = Std(close)*係数
input int      ATR_H1_Period            = 14;
input int      HM_Lookback_M5           = 120;         // バケット構築のM5本数（直近）
input double   HM_Bucket_Pips           = 2.0;         // バケット幅（pips）
input int      HM_Weight_A              = 30;          // A：スイング極値の投票重み
input int      HM_Weight_B              = 20;          // B：前日高安/当日始値の投票重み
input int      HM_Weight_D              = 50;          // D：日VWAP/H1累積VWAPの投票重み
input double   HM_Score_Threshold       = 58.0;        // 採用スコア閾値（0-100）
input double   EnterTol_H1ATR           = 0.45;        // 価格と帯の距離が ATR(H1)×係数以下で窓OPEN
input double   ExitTol_H1ATR            = 0.65;        // 離れが係数以上で窓CLOSE
input int      Window_TTL_M5            = 24;          // 窓の寿命（M5本数）
input int      Refire_Cooldown_M5       = 5;           // 窓終了後のクールダウン（M5本）
input int      SwingLB_M5               = 6;           // 直近高安探索本数（発注価格計算に使用）
input double   EntryBuffer_ATR_M5       = 0.12;        // 逆指値バッファ=ATR(M5)*係数（TRD側）
input double   EntryBuffer_RV_ATR_M5    = 0.10;        // RNG側の指値バッファ=ATR(M5)*係数
input int      MA20_M5_Period           = 20;          // Edge算出で使用（位置/傾きなど）
input double   Edge_Entry_Min           = 0.60;        // 0-1正規化の合成Edgeがこの値以上で発注許可
input int      RSI3_Period              = 3;           // RSI短期
input double   Burst_Delta              = 14.0;        // |ΔRSI(3)| しきい値（逆向き急転）
input double   Edge_Exit_Thresh         = 0.30;        // Edgeが2本連続でこの値未満でEXIT
input int      H1_Pivot_K               = 3;           // H1スイング検出の左右K
input double   SL_Extra_ATR_H1          = 0.20;        // スイング基準に追加する余裕（ATR(H1)*係数）
input bool     Use_SpreadFilter         = true;
input double   MaxSpread_Points         = 25;          // スプレッド上限（ポイント）
input int      MaxSimultaneousPositions = 1;           // 同時保有上限
input bool     OneShotPerWindow         = true;        // 1回発注で窓を閉じる
input bool     Enable_Log               = true;
input bool     Plot_Buffers             = true;

//+------------------------------------------------------------------+
//| 定数・列挙体                                                     |
//+------------------------------------------------------------------+
enum RegimeType { REGIME_NONE = 0, REGIME_TRD = 1, REGIME_RNG = 2 }; // H1回帰によるレジーム

// 窓のサイド（価格が帯より下ならUP=買い側、上ならDOWN=売り側）
enum WindowSide { SIDE_NONE = 0, SIDE_UP = 1, SIDE_DOWN = -1 };

// EXIT理由の列挙（集計用）
enum ExitReason { EXIT_NONE = 0, EXIT_STRUCT = 1, EXIT_BURST = 2, EXIT_EDGE = 3, EXIT_SL = 4 };

//+------------------------------------------------------------------+
//| 構造体                                                          |
//+------------------------------------------------------------------+
struct HeatmapCache
  {
   datetime lastH1Time;   // 最終計算したH1確定足の時間
   RegimeType regime;      // TRD or RNG
   double nearLevel;       // 最も近い帯の価格
   double nearScore;       // スコア（0-100）
   double atrH1;           // ATR(H1, shift=1)
   bool   valid;           // 計算が成功したか
  };

struct WindowState
  {
   bool   open;            // 窓が開いているか
   WindowSide side;        // 窓方向
   int    ttl;             // 残存M5本数
   int    cooldown;        // クールダウン残本数
   double level;           // 窓を開いた帯の価格
   double score;           // 帯スコア
  };

struct ExitStat
  {
   int total;
   int wins;
   double sumR;
   double maxDD;
   int structCount;
   int burstCount;
   int edgeCount;
   int slCount;
  };

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
CTrade g_trade;                       // 取引操作クラス
HeatmapCache g_hm = {0,REGIME_NONE,0.0,0.0,0.0,false};
WindowState  g_window = {false,SIDE_NONE,0,0,0.0,0.0};
ExitStat     g_stat = {0,0,0.0,0.0,0,0,0,0};

datetime g_lastM5Time = 0;            // 最終処理したM5確定足時間

// インジケータハンドル
int g_atrH1Handle = INVALID_HANDLE;
int g_atrM5Handle = INVALID_HANDLE;
int g_ma20M5Handle = INVALID_HANDLE;
int g_rsi3M5Handle = INVALID_HANDLE;

// 価格単位関連
int    g_digits = 0;
double g_point = 0.0;
double g_tickSize = 0.0;
double g_tickValue = 0.0;

double g_stopLevel = 0.0;
double g_freezeLevel = 0.0;

// 価格バッファ描画用
string HM_LINE_NAME = "HM_NEAR_LEVEL";
string WINDOW_RECT_NAME = "HM_WINDOW_RECT";

//+------------------------------------------------------------------+
//| ログ出力ヘルパー                                                |
//+------------------------------------------------------------------+
void LogPrint(const string text)
  {
   if(Enable_Log)
      Print(text);
  }

//+------------------------------------------------------------------+
//| 配列の最大・最小（シリーズ前提で簡易判定）                     |
//+------------------------------------------------------------------+
double MaxInRange(const double &arr[], int start, int count)
  {
   double m = arr[start];
   for(int i=start; i<start+count; i++)
      if(arr[i]>m) m=arr[i];
   return m;
  }

double MinInRange(const double &arr[], int start, int count)
  {
   double m = arr[start];
   for(int i=start; i<start+count; i++)
      if(arr[i]<m) m=arr[i];
   return m;
  }

//+------------------------------------------------------------------+
//| 価格の正規化（TickSize/Digitsを意識）                            |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   // TickSizeが最小単位のため、それに沿って丸めた後、表示桁で整える
   double step = g_tickSize;
   if(step<=0.0) step=_Point;
   double normalized = MathRound(price/step)*step;
   return NormalizeDouble(normalized, g_digits);
  }

//+------------------------------------------------------------------+
//| スプレッドチェック                                               |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   if(!Use_SpreadFilter)
      return true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask - bid)/g_point;
   return (spreadPts <= MaxSpread_Points);
  }

//+------------------------------------------------------------------+
//| H1回帰レジーム判定                                               |
//+------------------------------------------------------------------+
bool ComputeRegimeAndATR()
  {
   MqlRates rates[];
   int need = H1_Reg_Span + 2; // shift=1基準でspan本取得
   if(CopyRates(_Symbol, TF_Context, 1, need, rates) < H1_Reg_Span)
      return false;
   ArraySetAsSeries(rates, true);

   // 回帰用のy=close, x=0..span-1
   double meanX = 0.0;
   for(int i=0;i<H1_Reg_Span;i++) meanX += i;
   meanX /= H1_Reg_Span;

   double meanY = 0.0;
   for(int i=0;i<H1_Reg_Span;i++) meanY += rates[i].close;
   meanY /= H1_Reg_Span;

   double covXY = 0.0;
   double varX = 0.0;
   for(int i=0;i<H1_Reg_Span;i++)
     {
      double dx = i - meanX;
      double dy = rates[i].close - meanY;
      covXY += dx * dy;
      varX  += dx * dx;
     }
   if(varX<=0.0)
      return false;

   double beta = covXY/varX; // 単回帰の傾き

   // 標準偏差を計算
   double varY=0.0;
   for(int i=0;i<H1_Reg_Span;i++)
     {
      double dy = rates[i].close - meanY;
      varY += dy*dy;
     }
   double stdY = MathSqrt(varY / H1_Reg_Span);
   double thresh = stdY * H1_Reg_StdCoeff;

   g_hm.regime = (MathAbs(beta) >= thresh) ? REGIME_TRD : REGIME_RNG;
   g_hm.lastH1Time = rates[1].time; // shift=1の時間

   // ATR(H1)の取得（保険SLや距離評価で使用）
   double atrBuf[3];
   if(CopyBuffer(g_atrH1Handle, 0, 1, 3, atrBuf) < 2)
      return false;
   ArraySetAsSeries(atrBuf, true);
   g_hm.atrH1 = atrBuf[1];
   return true;
  }

//+------------------------------------------------------------------+
//| M5ウィンドウ用のMqlRates取得                                     |
//+------------------------------------------------------------------+
bool LoadM5Window(int count, MqlRates &out[])
  {
   if(CopyRates(_Symbol, TF_Trigger, 1, count, out) < count-1)
      return false;
   ArraySetAsSeries(out, true);
   return true;
  }

//+------------------------------------------------------------------+
//| スイング投票（左右=3固定）                                       |
//+------------------------------------------------------------------+
void VoteSwings(const MqlRates &m5[], int len, double lo, double bucket, double &scoreA[], int bucketCount)
  {
   // 最新バーはshift=0で未確定のため、shift=1以降のみ対象
   int k = 3;
   for(int i=k; i<len-k; i++)
     {
      double h = m5[i].high;
      double l = m5[i].low;
      bool isHigh = true;
      bool isLow = true;
      for(int j=1; j<=k; j++)
        {
         if(m5[i-j].high > h || m5[i+j].high > h) isHigh=false;
         if(m5[i-j].low < l  || m5[i+j].low < l)  isLow=false;
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
//| 前日高安・当日始値の投票                                         |
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
//| VWAP投票（日内VWAP＋H1累積VWAP直近値）                           |
//+------------------------------------------------------------------+
void VoteVWAP(const MqlRates &m5[], int len, const MqlRates &h1[], int h1len, double lo, double bucket, double &scoreD[], int bucketCount)
  {
   // 日内VWAP：当日内で典型価格×出来高累積 / 出来高累積
   double cumPV=0.0, cumV=0.0;
   datetime today = (m5[1].time/86400)*86400; // shift=1の足が属する日を使用
   for(int i=len-1; i>=1; i--)
     {
      datetime d = (m5[i].time/86400)*86400;
      if(d!=today) break; // 当日分のみ累積
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

   // H1累積VWAP：全期間累積（最新のみ使用）
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
//| ヒートマップ再構築                                               |
//+------------------------------------------------------------------+
bool RebuildHeatmap()
  {
   // M5データの取得
   MqlRates m5[];
   if(!LoadM5Window(HM_Lookback_M5+5, m5))
      return false;
   int len = ArraySize(m5);
   if(len<HM_Lookback_M5/2)
      return false;

   double highest = m5[0].high;
   double lowest  = m5[0].low;
   for(int i=1;i<HM_Lookback_M5 && i<len;i++)
     {
      if(m5[i].high>highest) highest=m5[i].high;
      if(m5[i].low <lowest)  lowest =m5[i].low;
     }
   double range = highest - lowest;
   double bucket = HM_Bucket_Pips * g_point; // pips幅をポイント換算
   if(bucket<=0.0 || range<=0.0)
      return false;

   int bucketCount = (int)MathCeil(range/bucket)+1;
   if(bucketCount<=0 || bucketCount>500)
      return false; // 安全のため上限

   double scoreA[]; ArrayResize(scoreA, bucketCount); ArrayInitialize(scoreA, 0.0);
   double scoreB[]; ArrayResize(scoreB, bucketCount); ArrayInitialize(scoreB, 0.0);
   double scoreD[]; ArrayResize(scoreD, bucketCount); ArrayInitialize(scoreD, 0.0);

   // H1データ（VWAP用）
   MqlRates h1[];
   CopyRates(_Symbol, TF_Context, 1, H1_Reg_Span+5, h1);
   ArraySetAsSeries(h1, true);

   VoteSwings(m5, len, lowest, bucket, scoreA, bucketCount);
   VotePrevDayLevels(lowest, bucket, scoreB, bucketCount);
   VoteVWAP(m5, len, h1, ArraySize(h1), lowest, bucket, scoreD, bucketCount);

   // 重み付けして0-100正規化
   double scores[]; ArrayResize(scores, bucketCount);
   double rawMax=0.0;
   for(int i=0;i<bucketCount;i++)
     {
      scores[i] = HM_Weight_A*scoreA[i] + HM_Weight_B*scoreB[i] + HM_Weight_D*scoreD[i];
      if(scores[i]>rawMax) rawMax=scores[i];
     }
   if(rawMax<=0.0)
      return false;

   for(int i=0;i<bucketCount;i++)
      scores[i] = (scores[i]/rawMax)*100.0;

   // スコア上位16の中から現在値に最も近い帯を抽出
   double buckets[]; ArrayResize(buckets, bucketCount);
   for(int i=0;i<bucketCount;i++) buckets[i] = lowest + bucket*i;

   // ソート用インデックス
   int idxs[]; ArrayResize(idxs, bucketCount);
   for(int i=0;i<bucketCount;i++) idxs[i]=i;
   // 簡易バブルソート（小規模なので許容）
   for(int i=0;i<bucketCount-1;i++)
     {
      for(int j=i+1;j<bucketCount;j++)
        {
         if(scores[idxs[i]] < scores[idxs[j]])
           {
            int tmp=idxs[i]; idxs[i]=idxs[j]; idxs[j]=tmp;
           }
        }
     }

   double priceNow = iClose(_Symbol, TF_Trigger, 1);
   double bestLevel=0.0, bestScore=0.0;
   bool found=false;
   int limit = (bucketCount<16)?bucketCount:16;
   for(int k=0;k<limit;k++)
     {
      int idx = idxs[k];
      double lv = buckets[idx];
      double sc = scores[idx];
      if(!found)
        {
         bestLevel=lv; bestScore=sc; found=true; continue;
        }
      double distCurr = MathAbs(lv - priceNow);
      double distBest = MathAbs(bestLevel - priceNow);
      if(distCurr < distBest || (distCurr==distBest && sc>bestScore))
        {
         bestLevel = lv;
         bestScore = sc;
        }
     }

   if(!found)
      return false;

   g_hm.nearLevel = NormalizePrice(bestLevel);
   g_hm.nearScore = bestScore;
   g_hm.valid = true;

   // 描画（任意）
   if(Plot_Buffers)
     {
      ObjectDelete(0, HM_LINE_NAME);
      ObjectCreate(0, HM_LINE_NAME, OBJ_HLINE, 0, 0, g_hm.nearLevel);
      ObjectSetInteger(0, HM_LINE_NAME, OBJPROP_COLOR, clrOrange);
      ObjectSetInteger(0, HM_LINE_NAME, OBJPROP_STYLE, STYLE_DASH);
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Edge合成 0-1（入口/出口共通）                                     |
//+------------------------------------------------------------------+
double ComputeEdge(bool isBuy)
  {
  double emaBuf[5];
  double atrBuf[5];
  double rsiBuf[5];
   ArraySetAsSeries(emaBuf, true); ArraySetAsSeries(atrBuf, true); ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(g_ma20M5Handle, 0, 1, 5, emaBuf) < 4) return 0.0;
   if(CopyBuffer(g_atrM5Handle, 0, 1, 5, atrBuf) < 4) return 0.0;
   if(CopyBuffer(g_rsi3M5Handle, 0, 1, 5, rsiBuf) < 4) return 0.0;

   double closePrice = iClose(_Symbol, TF_Trigger, 1);
   double atr = atrBuf[1];
   if(atr<=0.0) return 0.0;

   // 位置： (Close-EMA20)/(2*ATR) を [-1,1] -> [0,1]に正規化
   double posRaw = (closePrice - emaBuf[1])/(2.0*atr);
   posRaw = MathMax(-1.0, MathMin(1.0, posRaw));
   double posNorm = (posRaw + 1.0)/2.0;

   // 傾き： (EMA20-EMA20[3])/(3*ATR)
   double slopeRaw = (emaBuf[1] - emaBuf[4])/(3.0*atr);
   slopeRaw = MathMax(-1.0, MathMin(1.0, slopeRaw));
   double slopeNorm = (slopeRaw + 1.0)/2.0;

   // RSI：0-100 -> 0-1
   double rsiNorm = MathMax(0.0, MathMin(100.0, rsiBuf[1]))/100.0;

   // 構造：直近3本の高安パターンを0.5刻みで評価
   MqlRates m5[5];
   if(!LoadM5Window(5, m5)) return 0.0;
   double structScore = 0.0;
   if(isBuy)
     {
      if(m5[1].high > MathMax(m5[2].high, m5[3].high)) structScore += 0.5; // HH
      if(m5[1].low  >= MathMin(m5[2].low,  m5[3].low))  structScore += 0.5; // LLを割れていない
     }
   else
     {
      if(m5[1].low  < MathMin(m5[2].low, m5[3].low)) structScore += 0.5;  // LL
      if(m5[1].high <= MathMax(m5[2].high, m5[3].high)) structScore += 0.5; // HHを超えていない
     }

   // 重み付け：位置0.35, 傾き0.25, RSI0.25, 構造0.15
   double edge = 0.35*posNorm + 0.25*slopeNorm + 0.25*rsiNorm + 0.15*structScore;
   return MathMax(0.0, MathMin(1.0, edge));
  }

//+------------------------------------------------------------------+
//| StopLevelとFreezeLevelの安全価格補正                             |
//+------------------------------------------------------------------+
bool AdjustForStops(const ENUM_ORDER_TYPE orderType, double &price)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MathMax(g_stopLevel, g_freezeLevel) * g_point;

   if(orderType==ORDER_TYPE_BUY_STOP)
     {
      double minPrice = ask + minDist;
      if(price < minPrice) price = minPrice;
     }
   if(orderType==ORDER_TYPE_SELL_STOP)
     {
      double minPrice = bid - minDist;
      if(price > minPrice) price = minPrice;
     }
   price = NormalizePrice(price);

   // 最終チェック：距離を満たすか
   if(orderType==ORDER_TYPE_BUY_STOP && (price-ask) < minDist - 0.5*g_point)
      return false;
   if(orderType==ORDER_TYPE_SELL_STOP && (bid-price) < minDist - 0.5*g_point)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| 同方向の既存ポジション/注文を確認                                |
//+------------------------------------------------------------------+
bool DirectionAvailable(bool isBuy)
  {
   int posTotal = PositionsTotal();
   int ordTotal = OrdersTotal();
   int active=0;
   for(int i=0;i<posTotal;i++)
     {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      active++;
      ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((isBuy && t==POSITION_TYPE_BUY) || (!isBuy && t==POSITION_TYPE_SELL))
         return false; // 同方向あり
     }
   for(int i=0;i<ordTotal;i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=Magic) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      active++;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if((isBuy && t==ORDER_TYPE_BUY_STOP) || (!isBuy && t==ORDER_TYPE_SELL_STOP))
         return false;
     }
   // 同時保有上限
   if(active >= MaxSimultaneousPositions)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| H1スイングから保険SLを算出                                       |
//+------------------------------------------------------------------+
double ComputeInsuranceSL(double entryPrice, bool isBuy)
  {
   MqlRates h1[];
   int need = H1_Pivot_K*10 + 10;
   int copied = CopyRates(_Symbol, TF_Context, 1, need, h1);
   if(copied<=H1_Pivot_K*2) return 0.0;
   ArraySetAsSeries(h1, true);

   double atrBuf[3];
   if(CopyBuffer(g_atrH1Handle, 0, 1, 3, atrBuf) < 2) return 0.0;
   ArraySetAsSeries(atrBuf, true);
   double atr = atrBuf[1];

   // 直近5個までのピボットを探索
   int found=0;
   double target=0.0;
   for(int i=H1_Pivot_K; i<copied-H1_Pivot_K && found<5; i++)
     {
      bool isPivotHigh=true, isPivotLow=true;
      for(int k=1;k<=H1_Pivot_K;k++)
        {
         if(h1[i].high < h1[i-k].high || h1[i].high < h1[i+k].high) isPivotHigh=false;
         if(h1[i].low  > h1[i-k].low  || h1[i].low  > h1[i+k].low)  isPivotLow=false;
        }
      if(isBuy && isPivotLow && h1[i].low < entryPrice)
        {
         target = h1[i].low; found++; break;
        }
      if(!isBuy && isPivotHigh && h1[i].high > entryPrice)
        {
         target = h1[i].high; found++; break;
        }
     }

   if(found==0)
     target = isBuy ? entryPrice - 2.5*atr : entryPrice + 2.5*atr;

   // 追加の余裕をATRで付与
   if(isBuy)
      target -= SL_Extra_ATR_H1 * atr;
   else
      target += SL_Extra_ATR_H1 * atr;

   return NormalizePrice(target);
  }

//+------------------------------------------------------------------+
//| ロット計算（Risk%ベース、Stop距離必須）                          |
//+------------------------------------------------------------------+
double CalculateVolume(double entryPrice, double slPrice)
  {
   double riskAmount = AccountBalance() * (Risk_Percent/100.0);
   double stopDist = MathAbs(entryPrice - slPrice);
   if(stopDist<=0.0 || g_tickValue<=0.0 || g_tickSize<=0.0)
      return Lots_Min;
   double riskPerLot = (stopDist / g_tickSize) * g_tickValue;
   if(riskPerLot<=0.0) return Lots_Min;
   double vol = riskAmount / riskPerLot;

   // ブローカーのVolume制約に合わせて丸め
   double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep<=0.0) volStep=0.01;
   vol = MathMax(volMin, MathMin(vol, volMax));
   vol = MathMax(Lots_Min, MathMin(vol, Lots_Max));
   vol = MathFloor(vol/volStep)*volStep;
   vol = NormalizeDouble(vol, 2);
   return vol;
  }

//+------------------------------------------------------------------+
//| 逆指値発注処理                                                   |
//+------------------------------------------------------------------+
bool PlacePending(const bool isBuyStop, double price, double sl, const string reason)
  {
   ENUM_ORDER_TYPE type = isBuyStop ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   if(!AdjustForStops(type, price))
     {
      LogPrint("StopLevel不足のため発注断念: " + reason);
      return false;
     }

   double volume = CalculateVolume(price, sl);
   if(volume<=0.0)
     {
      LogPrint("ロット計算失敗で発注不可: " + reason);
      return false;
     }

   if(!DirectionAvailable(isBuyStop))
     {
      LogPrint("方向/同時保有制限で発注不可: " + reason);
      return false;
     }

   g_trade.SetExpertMagicNumber(Magic);
   g_trade.SetDeviationInPoints(20);

   bool sent = g_trade.OrderSend(_Symbol, type, volume, price, 0, sl, 0, reason);
   if(!sent)
     {
      int rc = g_trade.ResultRetcode();
      LogPrint(StringFormat("OrderSend失敗(%d) 再試行: %s", rc, reason));
      ResetLastError();
      sent = g_trade.OrderSend(_Symbol, type, volume, price, 0, sl, 0, reason);
      if(!sent)
        {
         rc = g_trade.ResultRetcode();
         LogPrint(StringFormat("OrderSend再試行も失敗(%d): %s", rc, reason));
         return false;
        }
     }

   LogPrint(StringFormat("逆指値セット %s 価格=%.5f SL=%.5f Vol=%.2f Edge/BandScore=%.2f/%.2f", isBuyStop?"BUY STOP":"SELL STOP", price, sl, volume, ComputeEdge(isBuyStop), g_hm.nearScore));

   // OneShotPerWindowなら窓を閉じてクールダウン開始
   if(OneShotPerWindow)
     {
      g_window.open=false;
      g_window.ttl=0;
      g_window.cooldown=Refire_Cooldown_M5;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| 窓のOPEN/CLOSE判定                                               |
//+------------------------------------------------------------------+
void UpdateWindowOnNewM5()
  {
   double price = iClose(_Symbol, TF_Trigger, 1);
   double dist = MathAbs(price - g_hm.nearLevel);
   double atr = g_hm.atrH1;

   // クールダウン減算
   if(g_window.cooldown>0)
      g_window.cooldown--;

   if(g_window.open)
     {
      g_window.ttl--;
      if(dist >= ExitTol_H1ATR*atr || g_window.ttl<=0)
        {
         LogPrint(StringFormat("窓CLOSE: dist=%.5f ATR=%.5f TTL=%d", dist, atr, g_window.ttl));
         g_window.open=false;
         g_window.cooldown = Refire_Cooldown_M5;
         ObjectDelete(0, WINDOW_RECT_NAME);
        }
     }
   else
     {
      if(g_window.cooldown==0 && g_hm.valid && g_hm.nearScore>=HM_Score_Threshold && dist <= EnterTol_H1ATR*atr)
        {
         g_window.open=true;
         g_window.ttl = Window_TTL_M5;
         g_window.side = (g_hm.nearLevel >= price)?SIDE_UP:SIDE_DOWN;
         g_window.level= g_hm.nearLevel;
         g_window.score= g_hm.nearScore;
         LogPrint(StringFormat("窓OPEN: level=%.5f score=%.2f side=%s dist=%.5f ATR=%.5f", g_window.level, g_window.score, (g_window.side==SIDE_UP?"UP":"DOWN"), dist, atr));

         if(Plot_Buffers)
           {
            ObjectDelete(0, WINDOW_RECT_NAME);
            datetime t1 = iTime(_Symbol, TF_Trigger, 1);
            datetime t2 = t1 + 60*5*Window_TTL_M5;
            ObjectCreate(0, WINDOW_RECT_NAME, OBJ_RECTANGLE, 0, t1, g_window.level+3*atr, t2, g_window.level-3*atr);
            ObjectSetInteger(0, WINDOW_RECT_NAME, OBJPROP_COLOR, clrAliceBlue);
            ObjectSetInteger(0, WINDOW_RECT_NAME, OBJPROP_BACK, true);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| エントリーフロー（窓OPEN中のM5確定で判定）                      |
//+------------------------------------------------------------------+
void TryEntryOnM5()
  {
   if(!g_window.open)
      return;
   if(!SpreadOK())
      return;

   double atrM5Buf[10];
   if(CopyBuffer(g_atrM5Handle, 0, 1, SwingLB_M5+2, atrM5Buf) < SwingLB_M5)
      return;
   ArraySetAsSeries(atrM5Buf, true);
   double atrM5 = atrM5Buf[1];
   if(atrM5<=0.0) return;

   MqlRates m5[];
   if(!LoadM5Window(SwingLB_M5+5, m5)) return;
   int len = ArraySize(m5);
   if(len < SwingLB_M5+2) return;

   double entry=0.0;
   bool isBuy=false;
   string orderReason="";

   if(g_hm.regime==REGIME_TRD)
     {
      if(g_window.side==SIDE_UP)
        {
         double maxHigh = m5[1].high;
         for(int i=1;i<=SwingLB_M5;i++) if(m5[i].high>maxHigh) maxHigh=m5[i].high;
         entry = maxHigh + EntryBuffer_ATR_M5*atrM5;
         isBuy = true;
         orderReason = "TRD_UP";
        }
      else if(g_window.side==SIDE_DOWN)
        {
         double minLow = m5[1].low;
         for(int i=1;i<=SwingLB_M5;i++) if(m5[i].low<minLow) minLow=m5[i].low;
         entry = minLow - EntryBuffer_ATR_M5*atrM5;
         isBuy = false;
         orderReason = "TRD_DOWN";
        }
     }
   else if(g_hm.regime==REGIME_RNG)
     {
      if(g_window.side==SIDE_UP)
        {
         double minLow = m5[1].low;
         for(int i=1;i<=SwingLB_M5;i++) if(m5[i].low<minLow) minLow=m5[i].low;
         entry = minLow - EntryBuffer_RV_ATR_M5*atrM5;
         isBuy = false; // 逆張りで売り
         orderReason = "RNG_UP_SELL";
        }
      else if(g_window.side==SIDE_DOWN)
        {
         double maxHigh = m5[1].high;
         for(int i=1;i<=SwingLB_M5;i++) if(m5[i].high>maxHigh) maxHigh=m5[i].high;
         entry = maxHigh + EntryBuffer_RV_ATR_M5*atrM5;
         isBuy = true; // 逆張りで買い
         orderReason = "RNG_DOWN_BUY";
        }
     }

   if(entry<=0.0)
      return;

   double edge = ComputeEdge(isBuy);
   if(edge < Edge_Entry_Min)
     {
      LogPrint(StringFormat("Edge不足で発注スキップ Edge=%.2f", edge));
      return;
     }

   double sl = ComputeInsuranceSL(entry, isBuy);
   if(sl<=0.0)
     {
      LogPrint("SL算出失敗で発注停止");
      return;
     }

   entry = NormalizePrice(entry);
   if(isBuy)
      PlacePending(true, entry, sl, orderReason);
   else
      PlacePending(false, entry, sl, orderReason);
  }

//+------------------------------------------------------------------+
//| EXIT判定（STRUCT→BURST→EDGE優先）                                |
//+------------------------------------------------------------------+
void CheckExitOnM5()
  {
   int posTotal = PositionsTotal();
   for(int i=0;i<posTotal;i++)
     {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool isBuy = (type==POSITION_TYPE_BUY);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);

      // 構造チェック（LL→LL or HH→HH）
      MqlRates m5[5];
      if(!LoadM5Window(5, m5)) continue;
      bool structExit=false;
      if(isBuy)
        structExit = (m5[1].low < m5[2].low && m5[2].low < m5[3].low);
      else
        structExit = (m5[1].high > m5[2].high && m5[2].high > m5[3].high);
      if(structExit)
        {
         double priceNow = PositionGetDouble(POSITION_PRICE_CURRENT);
         double r = (priceNow-entry)/(entry-sl);
         g_trade.PositionClose(PositionGetInteger(POSITION_TICKET));
         g_stat.structCount++; g_stat.total++;
         g_stat.sumR += r; if(r>0) g_stat.wins++; g_stat.maxDD = MathMin(g_stat.maxDD, r);
         LogPrint("EXIT STRUCT");
         continue;
        }

      // BURST：RSI差分と3連続高安
      double rsiBuf[4];
      ArraySetAsSeries(rsiBuf, true);
      if(CopyBuffer(g_rsi3M5Handle, 0, 1, 4, rsiBuf) < 3) continue;
      double delta = rsiBuf[1]-rsiBuf[2];
      bool burst=false;
      if(isBuy)
        burst = (m5[1].low < m5[2].low && m5[2].low < m5[3].low && delta<=-Burst_Delta);
      else
        burst = (m5[1].high > m5[2].high && m5[2].high > m5[3].high && delta>=Burst_Delta);
      if(burst)
        {
         double priceNow = PositionGetDouble(POSITION_PRICE_CURRENT);
         double r = (priceNow-entry)/(entry-sl);
         g_trade.PositionClose(PositionGetInteger(POSITION_TICKET));
         g_stat.burstCount++; g_stat.total++;
         g_stat.sumR += r; if(r>0) g_stat.wins++; g_stat.maxDD = MathMin(g_stat.maxDD, r);
         LogPrint("EXIT BURST");
         continue;
        }

      // EDGE：2本連続でEdgeが閾値未満
      double edge1 = ComputeEdge(isBuy);
      // 1本前のEdgeを近似するためEMA/RSIをshift=2で再計算
      double emaBuf[5]; double atrBuf[5]; double rsiBuf2[5];
      ArraySetAsSeries(emaBuf, true); ArraySetAsSeries(atrBuf, true); ArraySetAsSeries(rsiBuf2, true);
      if(CopyBuffer(g_ma20M5Handle, 0, 2, 5, emaBuf) < 4) continue;
      if(CopyBuffer(g_atrM5Handle, 0, 2, 5, atrBuf) < 4) continue;
      if(CopyBuffer(g_rsi3M5Handle, 0, 2, 5, rsiBuf2) < 4) continue;
      double close2 = iClose(_Symbol, TF_Trigger, 2);
      double atr2 = atrBuf[2];
      if(atr2<=0.0) continue;
      double posRaw2 = (close2 - emaBuf[2])/(2.0*atr2);
      posRaw2 = MathMax(-1.0, MathMin(1.0, posRaw2));
      double posNorm2 = (posRaw2+1.0)/2.0;
      double slopeRaw2 = (emaBuf[2]-emaBuf[3])/(3.0*atr2); // shift=2とshift=5相当（3本差）
      slopeRaw2 = MathMax(-1.0, MathMin(1.0, slopeRaw2));
      double slopeNorm2 = (slopeRaw2+1.0)/2.0;
      double rsiNorm2 = MathMax(0.0, MathMin(100.0, rsiBuf2[2]))/100.0;
      double struct2=0.0;
      if(isBuy)
        {
         if(m5[2].high > MathMax(m5[3].high, m5[4].high)) struct2+=0.5;
         if(m5[2].low  >= MathMin(m5[3].low, m5[4].low)) struct2+=0.5;
        }
      else
        {
         if(m5[2].low  < MathMin(m5[3].low, m5[4].low)) struct2+=0.5;
         if(m5[2].high <= MathMax(m5[3].high, m5[4].high)) struct2+=0.5;
        }
      double edge2 = 0.35*posNorm2 + 0.25*slopeNorm2 + 0.25*rsiNorm2 + 0.15*struct2;

      if(edge1<Edge_Exit_Thresh && edge2<Edge_Exit_Thresh)
        {
         double priceNow = PositionGetDouble(POSITION_PRICE_CURRENT);
         double r = (priceNow-entry)/(entry-sl);
         g_trade.PositionClose(PositionGetInteger(POSITION_TICKET));
         g_stat.edgeCount++; g_stat.total++;
         g_stat.sumR += r; if(r>0) g_stat.wins++; g_stat.maxDD = MathMin(g_stat.maxDD, r);
         LogPrint("EXIT EDGE");
        }
     }
  }

//+------------------------------------------------------------------+
//| 新規足検出（M5/H1）                                              |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
  {
   datetime t = iTime(_Symbol, tf, 1);
   if(t!=0 && t!=lastTime)
     {
      lastTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_DISABLED)
     {
      LogPrint("取引不可シンボル");
      return(INIT_FAILED);
     }

   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   g_atrH1Handle = iATR(_Symbol, TF_Context, ATR_H1_Period);
   g_atrM5Handle = iATR(_Symbol, TF_Trigger, ATR_H1_Period);
   g_ma20M5Handle= iMA(_Symbol, TF_Trigger, MA20_M5_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_rsi3M5Handle= iRSI(_Symbol, TF_Trigger, RSI3_Period, PRICE_CLOSE);
   if(g_atrH1Handle==INVALID_HANDLE || g_atrM5Handle==INVALID_HANDLE || g_ma20M5Handle==INVALID_HANDLE || g_rsi3M5Handle==INVALID_HANDLE)
     {
      LogPrint("インジケータ生成失敗");
      return(INIT_FAILED);
     }

   // 初回のH1計算
   if(!ComputeRegimeAndATR())
      LogPrint("初回レジーム計算失敗");
   if(!RebuildHeatmap())
      LogPrint("初回ヒートマップ計算失敗");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // オブジェクト削除
   ObjectDelete(0, HM_LINE_NAME);
   ObjectDelete(0, WINDOW_RECT_NAME);

   // 履歴からRを集計（Magic一致分）
   HistorySelect(0, TimeCurrent());
   double dd=0.0;
   int deals = HistoryDealsTotal();
   double sumR=0.0; int win=0; int total=0; int slCnt=g_stat.slCount;
   for(int i=0;i<deals;i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC)!=Magic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL)!=_Symbol) continue;
      long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entryType!=DEAL_ENTRY_OUT) continue;
      ulong orderTicket = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double priceIn = HistoryOrderGetDouble(orderTicket, ORDER_PRICE_OPEN);
      double priceOut= HistoryDealGetDouble(ticket, DEAL_PRICE);
      ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
      double dir = (dtype==DEAL_TYPE_SELL)?-1.0:1.0;
      double sl = HistoryDealGetDouble(ticket, DEAL_SL);
      if(priceIn==0.0 || priceIn==sl)
         continue; // 安全ガード（データ欠損や0除算防止）
      double r = (priceOut-priceIn)*dir/(priceIn - sl);
      sumR += r; total++; if(r>0) win++; if(r<dd) dd=r;
      if(HistoryDealGetInteger(ticket, DEAL_REASON)==DEAL_REASON_SL) slCnt++;
     }

   LogPrint(StringFormat("[SUMMARY] Magic:%d Symbol:%s Trades:%d Win%%:%.2f%% AvgR:%.2f MaxDD(R):%.2f STRUCT:%d BURST:%d EDGE:%d SL:%d",
                         Magic, _Symbol, total+g_stat.total, (win+g_stat.wins)*100.0/MathMax(1, total+g_stat.total),
                         (sumR+g_stat.sumR)/MathMax(1, total+g_stat.total), MathMin(dd, g_stat.maxDD), g_stat.structCount, g_stat.burstCount, g_stat.edgeCount, slCnt));
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   // H1確定足更新時のみ再計算
   if(IsNewBar(TF_Context, g_hm.lastH1Time))
     {
      if(ComputeRegimeAndATR())
         RebuildHeatmap();
     }

   // M5確定足で窓管理・Entry・Exit
   if(IsNewBar(TF_Trigger, g_lastM5Time))
     {
      // 窓管理
      if(g_hm.valid)
         UpdateWindowOnNewM5();
      // 約定管理（EXIT）
      CheckExitOnM5();
      // エントリ判定
      if(g_hm.valid)
         TryEntryOnM5();
     }
  }

//+------------------------------------------------------------------+
//| 補足：                                                           |
//| ・全判定は確定足(shift=1)のみ使用し、未確定値に依存しない。      |
//| ・ヒートマップ/レジームはH1更新時のみ再計算し、M5ではキャッシュ |
//|   を使用することで計算負荷を抑制。                               |
//| ・STRUCTはLL→LLまたはHH→HHのみとし、早期手仕舞いを抑制。         |
//| ・時間切れEXITを実装しない点は仕様に合わせて明示。             |
//+------------------------------------------------------------------+
