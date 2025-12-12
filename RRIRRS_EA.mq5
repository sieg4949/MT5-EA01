//+------------------------------------------------------------------+
//| RRI / RRS レンジ逆張りEA（15M推奨）                               |
//| ・しぐれさん用：高勝率寄りレンジ逆張り＋独自指標                 |
//| ・チャートのシンボル1つを対象。複数通貨ペアは各チャートに適用。 |
//+------------------------------------------------------------------+
#property strict
#property copyright "Rain"
#property link      ""
#property version   "1.00"
#property description "RRI / RRS を用いたレンジ逆張りEA（15M推奨）"

#include <Trade/Trade.mqh>

//--- 入力パラメータ（時間足・独自指標パラメータ）
input ENUM_TIMEFRAMES InpTF                   = PERIOD_M15; // メイン解析時間足（推奨：M15）
input int             InpRriWindowBars        = 32;         // RRI計算に使うバー数（約8時間分）
input int             InpRrsWindowBars        = 24;         // RRS計算に使うバー数（約6時間分）
input double          InpRriEntryMin          = 0.60;       // エントリー許可する最小RRI（レンジ度）
input double          InpRriExitMax           = 0.40;       // レジーム崩壊とみなすRRI（これ未満なら強制クローズ候補）
input double          InpRrsEntryThreshold    = 2.20;       // RRSエントリーしきい値（z-scoreの絶対値）

//--- リスク・ポジション関連
input double          InpRiskPerTradePercent  = 1.0;        // 1トレードあたりのリスク％（0で無効）
input double          InpFixedLot             = 0.00;       // 固定ロット（>0ならこちら優先）
input int             InpMaxPositions         = 1;          // このシンボルで同時保有する最大ポジション数
input int             InpMinBarsBetweenEntries= 4;          // 連続エントリーの間隔バー数（M15×4=約1時間）
input int             InpMaxHoldingBars       = 24;         // 最大保有バー数（M15×24=約6時間で時間切れ決済）

//--- SL/TPパラメータ
input double          InpSL_SigmaMult         = 2.5;        // 損切り距離：σ×この値
input double          InpTP_to_SL_Ratio       = 0.5;        // TP距離：SL距離×この比率（例：0.5なら勝ち：負け = 1：2）
input double          InpMinSL_Pips           = 5.0;        // 最小SL距離[pips]（あまりにも近すぎるSLを避ける）

//--- スプレッド・取引環境
input double          InpMaxSpreadPips        = 2.0;        // 許容最大スプレッド[pips]
input uint            InpMagic                = 20251215;   // マジックナンバー
input int             InpSlippagePoints       = 20;         // 許容スリッページ[points]

//--- 内部変数
CTrade   trade;                      // 取引用クラス
datetime g_lastCalcBarTime = 0;      // 最後に計算したバーの時間（新バー判定用）
datetime g_lastEntryBarTime = 0;     // 最後にエントリーしたバーの時間（過剰エントリー抑制用）

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // 取引関連の初期設定
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);      // シンボルに応じたFILLINGモード自動設定
   trade.SetDeviationInPoints(InpSlippagePoints);

   g_lastCalcBarTime  = 0;
   g_lastEntryBarTime = 0;

   // バー数チェック：最小限のバーがないと計算できないので警告のみ出す
   int needBars = MathMax(InpRriWindowBars, InpRrsWindowBars) + 2;
   if(Bars(_Symbol, InpTF) < needBars)
   {
      Print("OnInit: バーが不足しています。履歴が十分にダウンロードされているか確認してください。必要バー数=",
            needBars, " 現在=", Bars(_Symbol, InpTF));
   }

   Print("EA 初期化完了: シンボル=", _Symbol, " / 時間足=", EnumToString(InpTF));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA 終了: reason=", reason);
}

//+------------------------------------------------------------------+
//| ティック到来時メイン処理                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 新しいバーが確定したタイミングだけロジックを動かす
   datetime current_bar_time;
   if(!IsNewBar(current_bar_time))
      return;

   //--- まず既存ポジションの管理（時間切れ・レンジ崩壊など）
   ManageOpenPositions();

   //--- 次に新規エントリー判定
   TryNewEntry();
}

//+------------------------------------------------------------------+
//| 新しいバーかどうか判定する                                       |
//| out_bar_time: 現在のバー(shift=0)の時間を返す                    |
//+------------------------------------------------------------------+
bool IsNewBar(datetime &out_bar_time)
{
   // 指定時間足の現在バーの時間を取得
   datetime t = iTime(_Symbol, InpTF, 0);
   if(t == 0)
      return(false);

   // 前回と同じ時間なら同じバーなので何もしない
   if(t == g_lastCalcBarTime)
      return(false);

   // 時間が変わった＝新しいバーが始まった
   g_lastCalcBarTime = t;
   out_bar_time      = t;
   return(true);
}

//+------------------------------------------------------------------+
//| 既存ポジションの管理（時間切れ・レジーム崩壊によるクローズ）     |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int total = PositionsTotal();
   if(total <= 0)
      return;

   // 最大保有時間を秒に変換（入力がバー数なので、時間足から秒数を算出）
   int period_sec = PeriodSeconds(InpTF);
   if(period_sec <= 0)
      period_sec = 60 * 15; // 念のため15分をデフォルトにしておく
   int max_hold_sec = InpMaxHoldingBars * period_sec;

   datetime now = TimeCurrent();

   // レジーム崩壊判定用のRRIを計算
   double rri_exit = 0.0;
   bool   rri_ok   = CalcRRI(_Symbol, InpTF, 1, InpRriWindowBars, rri_exit);

   // ポジションを後ろから順にチェック（クローズ時のインデックスずれを防ぐため）
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string   sym       = PositionGetString(POSITION_SYMBOL);
      long     type      = PositionGetInteger(POSITION_TYPE);
      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);

      if(sym != _Symbol)
         continue; // このEAはチャートシンボルのみ管理

      bool need_close = false;
      string reason   = "";

      //--- 時間切れ決済
      if(max_hold_sec > 0)
      {
         int seconds_held = (int)(now - open_time);
         if(seconds_held >= max_hold_sec)
         {
            need_close = true;
            reason     = "TimeExit(保有時間超過)";
         }
      }

      //--- レンジ崩壊（RRIが閾値未満）による決済
      if(!need_close && rri_ok && rri_exit < InpRriExitMax)
      {
         need_close = true;
         reason     = "RegimeExit(RRI低下)";
      }

      //--- 必要ならクローズ
      if(need_close)
      {
         PrintFormat("ManageOpenPositions: %s ticket=%I64u をクローズします。理由=%s, RRI=%.3f",
                     sym, ticket, reason, rri_exit);
         if(!trade.PositionClose(ticket))
         {
            PrintFormat("ManageOpenPositions: ticket=%I64u のクローズに失敗しました。Error=%d",
                        ticket, GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 新規エントリー判定                                               |
//+------------------------------------------------------------------+
void TryNewEntry()
{
   //--- 必要なバー数が揃っていなければ何もしない
   int needBars = MathMax(InpRriWindowBars, InpRrsWindowBars) + 2;
   if(Bars(_Symbol, InpTF) < needBars)
      return;

   //--- スプレッドチェック
   double spread_pips = GetCurrentSpreadPips();
   if(spread_pips < 0)
      return; // 取得に失敗した場合は安全のためスキップ

   if(spread_pips > InpMaxSpreadPips)
   {
      PrintFormat("TryNewEntry: スプレッドが広すぎるためエントリー回避 (%.2f pips > 許容 %.2f)",
                  spread_pips, InpMaxSpreadPips);
      return;
   }

   //--- 既存ポジション数チェック
   int pos_count = CountOpenPositions(_Symbol);
   if(pos_count >= InpMaxPositions)
   {
      // ポジション保有上限に到達しているので新規エントリーしない
      return;
   }

   //--- 連続エントリー間隔チェック
   //     最終エントリーから InpMinBarsBetweenEntries バー未満ならエントリーしない
   if(InpMinBarsBetweenEntries > 0 && g_lastEntryBarTime != 0)
   {
      datetime last_closed_bar = iTime(_Symbol, InpTF, 1); // 直近確定バー時間
      int period_sec = PeriodSeconds(InpTF);
      if(period_sec <= 0)
         period_sec = 60 * 15;

      int bars_since =
         (int)((last_closed_bar - g_lastEntryBarTime) / period_sec);

      if(bars_since < InpMinBarsBetweenEntries)
      {
         // まだ間隔が足りないのでスキップ
         return;
      }
   }

   //--- RRI / RRS を計算
   double rri      = 0.0;
   double rrs      = 0.0;
   double sigma    = 0.0;
   double median   = 0.0;

   if(!CalcRriRrs(_Symbol, InpTF, 1,
                  InpRriWindowBars, InpRrsWindowBars,
                  rri, rrs, sigma, median))
   {
      // 計算できなかった場合（バー不足・σ=0など）は何もしない
      return;
   }

   //--- レンジ度チェック（RRI が十分に高いときだけ逆張りを行う）
   if(rri < InpRriEntryMin)
   {
      // トレンド気味と判断してスキップ
      return;
   }

   //--- RRS に基づいて方向を決定
   int direction = 0;  // +1: BUY / -1: SELL / 0: エントリーなし
   if(rrs <= -InpRrsEntryThreshold)
      direction = +1;  // 下方向に行き過ぎ → ロング逆張り
   else if(rrs >= +InpRrsEntryThreshold)
      direction = -1;  // 上方向に行き過ぎ → ショート逆張り
   else
      return;          // 行き過ぎとまでは言えないので見送り

   //--- SL/TP 距離の計算（σベース）
   double pip_size = GetPipSize();
   if(pip_size <= 0.0)
      return;

   // σ×係数で価格単位の距離を決める
   double sl_dist_price = sigma * InpSL_SigmaMult;

   // 最小SL距離（pips）を価格単位に変換し、それ未満なら引き上げる
   double min_sl_dist_price = InpMinSL_Pips * pip_size;
   if(sl_dist_price < min_sl_dist_price)
      sl_dist_price = min_sl_dist_price;

   // TP距離は SL距離×比率
   double tp_dist_price = sl_dist_price * InpTP_to_SL_Ratio;

   //--- おおよそのエントリー価格を取得（リスク計算用）
   double entry_price_est;
   if(direction > 0)
      entry_price_est = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else
      entry_price_est = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(entry_price_est <= 0)
      return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl_price, tp_price;

   if(direction > 0) // BUY
   {
      sl_price = entry_price_est - sl_dist_price;
      tp_price = entry_price_est + tp_dist_price;
   }
   else // SELL
   {
      sl_price = entry_price_est + sl_dist_price;
      tp_price = entry_price_est - tp_dist_price;
   }

   sl_price = NormalizeDouble(sl_price, digits);
   tp_price = NormalizeDouble(tp_price, digits);

   //--- ロット計算
   double sl_distance_for_risk = MathAbs(entry_price_est - sl_price);
   double volume = CalculatePositionSize(sl_distance_for_risk);
   if(volume <= 0.0)
   {
      Print("TryNewEntry: 計算されたロットが0以下のためエントリーを見送りました。");
      return;
   }

   //--- 実際のエントリー実行
   bool   result = false;
   string comment;

   if(direction > 0)
   {
      comment = "RRI_RRS_Long";
      result  = trade.Buy(volume, _Symbol, 0.0, sl_price, tp_price, comment);
   }
   else
   {
      comment = "RRI_RRS_Short";
      result  = trade.Sell(volume, _Symbol, 0.0, sl_price, tp_price, comment);
   }

   if(result)
   {
      // ここで直近確定バー時間を「エントリーしたバー」として記録
      g_lastEntryBarTime = iTime(_Symbol, InpTF, 1);

      PrintFormat("TryNewEntry: %s エントリー成功 direction=%s volume=%.2f RRI=%.3f RRS=%.3f SL=%.5f TP=%.5f",
                  _Symbol,
                  (direction > 0 ? "BUY" : "SELL"),
                  volume, rri, rrs, sl_price, tp_price);
   }
   else
   {
      PrintFormat("TryNewEntry: エントリー失敗 direction=%s Error=%d",
                  (direction > 0 ? "BUY" : "SELL"),
                  GetLastError());
   }
}

//+------------------------------------------------------------------+
//| 現在のスプレッド[pips]を取得                                     |
//+------------------------------------------------------------------+
double GetCurrentSpreadPips()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return(-1.0);

   long spread_points = (long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread_points < 0)
      return(-1.0);

   double pip_size = GetPipSize();
   if(pip_size <= 0.0)
      return(-1.0);

   // spread_points × point が価格差、それをpips単位に変換
   double spread_price = (double)spread_points * point;
   double spread_pips  = spread_price / pip_size;
   return(spread_pips);
}

//+------------------------------------------------------------------+
//| このシンボルの「1pips」の価格単位を取得                           |
//| 3桁・5桁通貨：point×10、それ以外：point を pips とみなす          |
//+------------------------------------------------------------------+
double GetPipSize()
{
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(point <= 0.0)
      return(0.0);

   if(digits == 3 || digits == 5)
      return(point * 10.0);  // 例: USDJPY 150.123 (point=0.001) → pip=0.01
   else
      return(point);         // 2桁・4桁などは point = 1 pip とみなす
}

//+------------------------------------------------------------------+
//| 指定シンボルのオープンポジション数をカウント                      |
//+------------------------------------------------------------------+
int CountOpenPositions(const string symbol)
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym == symbol)
         count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| ロット計算                                                       |
//| ・固定ロットが設定されていればそれを優先                         |
//| ・それ以外は「口座残高×リスク％ / 損切り距離」に基づく簡易計算    |
//+------------------------------------------------------------------+
double CalculatePositionSize(double sl_distance_price)
{
   //--- 固定ロット優先
   if(InpFixedLot > 0.0)
      return(NormalizeVolume(InpFixedLot));

   //--- リスク％が0以下ならロットは計算しない
   if(InpRiskPerTradePercent <= 0.0 || sl_distance_price <= 0.0)
      return(0.0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * InpRiskPerTradePercent / 100.0;
   if(risk_money <= 0.0)
      return(0.0);

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0)
      return(0.0);

   // 1ロットあたりの概算損失額 = (SL距離 / tick_size) × tick_value
   double loss_per_lot = (sl_distance_price / tick_size) * tick_value;
   if(loss_per_lot <= 0.0)
      return(0.0);

   double volume = risk_money / loss_per_lot;
   return(NormalizeVolume(volume));
}

//+------------------------------------------------------------------+
//| ロットをブローカー許容範囲＆ステップに丸める                     |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   // ステップ単位に切り捨て
   double v = MathFloor(volume / step) * step;

   // 最小・最大ロットでクリップ
   v = MathMax(v, minv);
   v = MathMin(v, maxv);

   if(v < minv)
      return(0.0);

   return(v);
}

//+------------------------------------------------------------------+
//| RRI / RRS をまとめて計算                                         |
//| shift: 1 を指定すると「直近確定バー」を基準に計算                 |
//+------------------------------------------------------------------+
bool CalcRriRrs(const string symbol,
                ENUM_TIMEFRAMES tf,
                int shift,
                int rri_window,
                int rrs_window,
                double &out_rri,
                double &out_rrs,
                double &out_sigma,
                double &out_median)
{
   if(!CalcRRI(symbol, tf, shift, rri_window, out_rri))
      return(false);

   if(!CalcRRS(symbol, tf, shift, rrs_window,
               out_rrs, out_sigma, out_median))
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
//| RRI (Rain Range Index) 計算                                      |
//| ・過去 window 本の終値を線形回帰し、傾きと値幅から               |
//|   「どれだけレンジっぽいか」を 0〜1 に正規化                     |
//|   1 に近いほどレンジ、0 に近いほどトレンド                       |
//+------------------------------------------------------------------+
bool CalcRRI(const string symbol,
             ENUM_TIMEFRAMES tf,
             int shift,
             int window,
             double &out_rri)
{
   if(window <= 1)
      return(false);

   int bars = Bars(symbol, tf);
   if(bars <= shift + window)
      return(false);

   double closes[];
   ArrayResize(closes, window);

   int copied = CopyClose(symbol, tf, shift, window, closes);
   if(copied != window)
      return(false);

   // 線形回帰 (x: 0〜window-1, y: close)
   double sum_x  = 0.0;
   double sum_y  = 0.0;
   double sum_x2 = 0.0;
   double sum_xy = 0.0;

   for(int i = 0; i < window; i++)
   {
      double x = (double)i;
      double y = closes[i];

      sum_x  += x;
      sum_y  += y;
      sum_x2 += x * x;
      sum_xy += x * y;
   }

   double n      = (double)window;
   double denom  = (n * sum_x2 - sum_x * sum_x);
   double slope  = 0.0;

   if(denom != 0.0)
      slope = (n * sum_xy - sum_x * sum_y) / denom;
   else
      slope = 0.0;

   // 値幅（終値ベース）
   double minv = closes[0];
   double maxv = closes[0];
   for(int i = 1; i < window; i++)
   {
      if(closes[i] < minv) minv = closes[i];
      if(closes[i] > maxv) maxv = closes[i];
   }

   double range = maxv - minv;
   if(range <= 0.0)
   {
      // 全く動いていない場合は「レンジ」とみなし 1.0 を返す
      out_rri = 1.0;
      return(true);
   }

   // 1本あたりの平均的な変動幅
   double norm = range / n;
   double s    = MathAbs(slope);

   // slope が norm と同じくらいなら「強いトレンド」→ RRI ≒ 0
   // slope が 0 に近ければ「レンジ」→ RRI ≒ 1
   double rri = 1.0 - (s / norm);
   if(rri < 0.0) rri = 0.0;
   if(rri > 1.0) rri = 1.0;

   out_rri = rri;
   return(true);
}

//+------------------------------------------------------------------+
//| RRS (Rain Reversal Score) 計算                                   |
//| ・過去window本の終値の中央値＋MADから z-score を算出             |
//|   → 終値が中央値からどれだけ行き過ぎているか                     |
//+------------------------------------------------------------------+
bool CalcRRS(const string symbol,
             ENUM_TIMEFRAMES tf,
             int shift,
             int window,
             double &out_rrs,
             double &out_sigma,
             double &out_median)
{
   if(window <= 1)
      return(false);

   int bars = Bars(symbol, tf);
   if(bars <= shift + window)
      return(false);

   double closes[];
   ArrayResize(closes, window);

   int copied = CopyClose(symbol, tf, shift, window, closes);
   if(copied != window)
      return(false);

   double last_close = closes[0];

   // 中央値を算出
   double median = 0.0;
   if(!MedianFromArray(closes, window, median))
      return(false);

   // MAD（中央値からの絶対偏差の中央値）を算出
   double deviations[];
   ArrayResize(deviations, window);
   for(int i = 0; i < window; i++)
      deviations[i] = MathAbs(closes[i] - median);

   double mad = 0.0;
   if(!MedianFromArray(deviations, window, mad))
      return(false);

   // MAD → σ相当への変換（正規分布仮定で ≒1.4826 倍）
   double sigma = mad * 1.4826;
   if(sigma <= 0.0)
      return(false);

   double rrs = (last_close - median) / sigma;

   out_rrs   = rrs;
   out_sigma = sigma;
   out_median= median;
   return(true);
}

//+------------------------------------------------------------------+
//| 配列の中央値を計算（内部でコピー＆ソート）                       |
//+------------------------------------------------------------------+
bool MedianFromArray(const double &src[], int size, double &out_median)
{
   if(size <= 0)
      return(false);

   double tmp[];
   ArrayResize(tmp, size);
   for(int i = 0; i < size; i++)
      tmp[i] = src[i];

   // 昇順ソート
   ArraySort(tmp, WHOLE_ARRAY, 0, MODE_ASCENDING);

   if((size % 2) == 1)
   {
      // 要素数が奇数 → 真ん中の値
      out_median = tmp[size / 2];
   }
   else
   {
      // 偶数 → 中央2つの平均
      int idx = size / 2;
      out_median = 0.5 * (tmp[idx - 1] + tmp[idx]);
   }
   return(true);
}
//+------------------------------------------------------------------+
