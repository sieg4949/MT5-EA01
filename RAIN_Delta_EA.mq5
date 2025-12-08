//+------------------------------------------------------------------+
//| RAIN_Delta_EA_Phase1.mq5                                         |
//| ドル円(USDJPY)想定 / マルチタイム・マルチアルファEA骨格         |
//| Phase1: クラス構造・イベントフローのみ実装                       |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

//--- EAの基本情報（必要に応じて調整）
#property copyright "RAIN Delta EA Phase1"
#property link      ""
#property version   "1.00"
#property description "H1/H4レジーム判定 + M5/M1アルファ構造のEA骨格"

//==================================================================
// 入力パラメータ
//==================================================================

//--- リスク関連
input double InpRiskPerTrade        = 0.5;   // 1トレードあたり口座残高に対するリスク[%]
input double InpWarnDailyDD         = 2.0;   // 日次DD 警告閾値[%]
input double InpMaxDailyDD          = 3.0;   // 日次DD 最大許容[%]
input double InpMaxWeeklyDD         = 5.0;   // 週次DD 最大許容[%]

//--- 取引時間帯（ブローカー時間前提。必要ならオフセットでJSTに合わせる）
input int    InpTradeStartHour      = 16;    // 取引開始時刻（時）
input int    InpTradeEndHour        = 3;     // 取引終了時刻（時）※翌日またぎのケースあり

//--- ニュースフィルタ（Phase1ではダミー実装）
input bool   InpUseNewsFilter       = false; // ニュースフィルタを使うか
input int    InpNewsStopMinutesBefore = 30;  // ニュース前 停止分
input int    InpNewsStopMinutesAfter  = 30;  // ニュース後 停止分

//--- スプレッド・ATR関連
input double InpMaxSpreadPips       = 1.2;   // 絶対スプレッド上限[pips]
input double InpMaxSpreadATRRatio   = 0.3;   // Spread / ATR_M1 の比率上限
input double InpMinTargetToSpreadRatio = 4.0;// TP距離 / Spread の最小比率

//--- レジーム判定（H1）
input int    InpH1_MA_Fast          = 20;
input int    InpH1_MA_Slow          = 50;
input int    InpH1_ADX_Period       = 14;
input double InpTrend_ADX_Min       = 20.0;
input double InpRange_ADX_Max       = 15.0;
input double InpTrend_MA_ATR_DiffMin= 0.3;
input double InpRange_MA_ATR_DiffMax= 0.2;
input int    InpRegimeCooldownBars_H1 = 3;

//--- AlphaA: 圧縮ブレイク
input int    InpA_Lookback_M5       = 12;
input double InpA_Range_ATR_Ratio_Max = 2.3;
input double InpA_InsideRateMin     = 0.27;
input double InpA_EntryOffsetATR    = 0.25;
input double InpA_SL_ATR            = 1.3;
input double InpA_TP1_ATR           = 1.5;
input double InpA_TP2_TrailATR      = 1.0;

//--- AlphaB: AVWAP回帰
input double InpB_Deviation_ATR_H1  = 0.9;
input double InpB_SL_ATR_H1         = 1.0;
input double InpB_TP_Offset_ATR_H1  = 0.3;

//--- AlphaC: ミニスイング
input int    InpC_PatternDepthBars  = 3;
input double InpC_SL_ATR_M1         = 0.8;
input double InpC_TP_ATR_M1         = 1.3;
input int    InpC_MaxHoldBars_M1    = 30;

//--- FOMO 関連（追い回し禁止）
input int    InpFomoBlockBars_M1    = 5;     // 損切り/不成立後、このバー数だけ再エントリ禁止

//--- マジックナンバー
input int    InpMagicBase           = 560000;// EA共通のベースマジック番号


//==================================================================
// 共通の型・定数定義
//==================================================================

//--- レジーム区分
enum ENUM_REGIME
  {
   REGIME_UNKNOWN = 0,
   REGIME_TREND   = 1,
   REGIME_RANGE   = 2,
   REGIME_CHAOS   = 3
  };

//--- シグナル種別（売買方向）
enum ENUM_SIGNAL_SIDE
  {
   SIGNAL_NONE  = 0,
   SIGNAL_BUY   = 1,
   SIGNAL_SELL  = -1
  };

//--- シグナル構造体
struct TradeSignal
  {
   bool             is_valid;   // シグナル有無
   ENUM_SIGNAL_SIDE side;       // 売買方向
   double           price;      // エントリー価格（0なら成行扱い）
   double           sl;         // ストップロス価格
   double           tp;         // テイクプロフィット価格
   int              magic;      // マジック番号
   string           comment;    // 注文コメント
  };

//==================================================================
// ログ出力系（単純なラッパ関数）
//==================================================================

//+------------------------------------------------------------------+
//| ログフォーマット共通化                                          |
//| level: "INFO","WARN","ERROR" など                                |
//| tag  : "INIT","REGIME","ALPHAA" など                              |
//+------------------------------------------------------------------+
void LogPrint(string level, string tag, string msg)
  {
   string t = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   PrintFormat("[%s][%s][%s] %s", t, level, tag, msg);
  }

//+------------------------------------------------------------------+
//| CanOpen 用のログ間引きヘルパ                                    |
//| - Spread/ATR 以外の判定ログは頻出しやすいため、同じ理由が短時間 |
//|   に連続発生しても一定秒数に 1 回だけ出力するように制御する。  |
//| - 引数 reason でログ理由のカテゴリ文字列を渡し、前回理由が変わ |
//|   った場合は即座に出力し、同一理由が続く場合のみ間隔制御する。 |
//+------------------------------------------------------------------+
bool ShouldLogCanOpenNonATR(const string reason,
                            datetime &last_time,
                            string   &last_reason,
                            const int interval_sec)
  {
   // まだ一度も出力していない、または理由が変わった場合は即出力
   if(last_reason != reason)
     {
      last_reason = reason;
      last_time   = TimeCurrent();
      return(true);
     }

   // 同一理由が続いている場合は、指定秒数以上経過したら出力を許可
   if(TimeCurrent() - last_time >= interval_sec)
     {
      last_time = TimeCurrent();
      return(true);
     }

   // それ以外は間引く
   return(false);
  }

//==================================================================
// 日付計算ユーティリティ
//==================================================================

//+------------------------------------------------------------------+
//| 日付の 0:00 を返す                                               |
//| 例: 2024/01/02 15:30 -> 2024/01/02 00:00                         |
//| MqlDateTime に分解して時分秒を 0 に揃えることで、日付境界判定の |
//| 基準となる値を生成する。                                         |
//+------------------------------------------------------------------+
datetime DateOfDay(datetime t)
  {
   MqlDateTime mt;
   TimeToStruct(t, mt);
   mt.hour = 0;
   mt.min  = 0;
   mt.sec  = 0;
   return StructToTime(mt);
  }

//+------------------------------------------------------------------+
//| 週の開始日（月曜 0:00）を返す                                   |
//| MqlDateTime.day_of_week は 0=日曜, 1=月曜 ... のため、           |
//| 「今週の月曜 0:00」まで日単位で巻き戻した時刻を求める。        |
//+------------------------------------------------------------------+
datetime WeekStartMonday(datetime t)
  {
   datetime today_start = DateOfDay(t);
   MqlDateTime mt;
   TimeToStruct(today_start, mt);

   // day_of_week が 1 のときは同日の 0:00 が週初。0(日曜)の場合は6日前。
   int offset_days = (mt.day_of_week == 0) ? 6 : (mt.day_of_week - 1);
   return today_start - (offset_days * 86400);
  }

//==================================================================
// CRegimeEngine : H1/H4レジーム判定クラス（骨格）
//==================================================================
class CRegimeEngine
  {
private:
   int      m_regime;          // 現在レジーム
   double   m_trend_dir;       // トレンド方向 -1/0/1
   datetime m_last_change_time;// 最終レジーム変更時刻

   //--- インジケータハンドル（実装時に使用）
   int      m_handle_ma_fast_h1;
   int      m_handle_ma_slow_h1;
   int      m_handle_adx_h1;
   int      m_handle_atr_h1;

public:
                     CRegimeEngine();
   void              Init();
   void              Reset();
   void              OnNewBarH1(); // H1確定時に呼ぶ
   int               Regime() const { return m_regime; }
   double            TrendDir() const { return m_trend_dir; }
   bool              InCooldown() const;
  };

//--- コンストラクタ
CRegimeEngine::CRegimeEngine()
  {
   m_regime           = REGIME_UNKNOWN;
   m_trend_dir        = 0.0;
   m_last_change_time = 0;
   m_handle_ma_fast_h1 = INVALID_HANDLE;
   m_handle_ma_slow_h1 = INVALID_HANDLE;
   m_handle_adx_h1     = INVALID_HANDLE;
   m_handle_atr_h1     = INVALID_HANDLE;
  }

//--- 初期化（OnInitで呼び出し）
void CRegimeEngine::Init()
  {
   // H1 のトレンド・レジーム判定に使用するインジケータハンドルを生成する
   // - EMA(終値) 2 本でトレンド方向と強さを確認
   // - ADX でトレンドの強さを確認
   // - ATR でボラティリティを取得し、MA差との比率を計算する
   m_handle_ma_fast_h1 = iMA(_Symbol, PERIOD_H1, InpH1_MA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   m_handle_ma_slow_h1 = iMA(_Symbol, PERIOD_H1, InpH1_MA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   // ADX は MQL5 でシンボル・時間足・期間のみを受け取るため、余分な引数は渡さない
   // （PRICE_CLOSE を指定するとパラメータ数不一致でコンパイルエラーになる）
   m_handle_adx_h1     = iADX(_Symbol, PERIOD_H1, InpH1_ADX_Period);
   m_handle_atr_h1     = iATR(_Symbol, PERIOD_H1, 14);

   if(m_handle_ma_fast_h1==INVALID_HANDLE ||
      m_handle_ma_slow_h1==INVALID_HANDLE ||
      m_handle_adx_h1    ==INVALID_HANDLE ||
      m_handle_atr_h1    ==INVALID_HANDLE)
     {
      // いずれかのハンドル生成に失敗した場合はエラーログを出す
      LogPrint("ERROR", "REGIME", "CRegimeEngine::Init: H1 インジケータハンドルの作成に失敗しました。");
     }
   else
     {
      LogPrint("INFO", "REGIME", "CRegimeEngine::Init 完了（H1 インジケータハンドル作成済み）");
     }
  }


//--- リセット
void CRegimeEngine::Reset()
  {
   m_regime           = REGIME_UNKNOWN;
   m_trend_dir        = 0.0;
   m_last_change_time = 0;
  }

//--- H1新バー時に呼び出し（レジーム更新）
void CRegimeEngine::OnNewBarH1()
  {
   // H1 の新バー確定タイミングでレジーム判定を行う。
   // 仕様どおり「確定バー（shift=1）」の値のみを使い、未確定バーは一切見ない。

   // インジケータハンドルが未初期化の場合は安全側に倒してスキップ
   if(m_handle_ma_fast_h1==INVALID_HANDLE ||
      m_handle_ma_slow_h1==INVALID_HANDLE ||
      m_handle_adx_h1    ==INVALID_HANDLE ||
      m_handle_atr_h1    ==INVALID_HANDLE)
     {
      LogPrint("WARN", "REGIME", "OnNewBarH1: インジケータハンドル未初期化のためレジーム更新をスキップします。");
      return;
     }

   double ma_fast[1];
   double ma_slow[1];
   double adx_val[1];
   double atr_val[1];

   // H1 確定バー（shift=1）の値を取得
   if(CopyBuffer(m_handle_ma_fast_h1, 0, 1, 1, ma_fast) != 1 ||
      CopyBuffer(m_handle_ma_slow_h1, 0, 1, 1, ma_slow) != 1 ||
      CopyBuffer(m_handle_adx_h1,     0, 1, 1, adx_val) != 1 ||
      CopyBuffer(m_handle_atr_h1,     0, 1, 1, atr_val) != 1)
     {
      LogPrint("WARN", "REGIME", "OnNewBarH1: CopyBuffer に失敗したためレジーム更新をスキップします。");
      return;
     }

   double ma_diff = ma_fast[0] - ma_slow[0];  // トレンド方向と強さを見るための MA 差
   double atr     = atr_val[0];              // H1 ATR
   double adx     = adx_val[0];              // トレンドの強さ

   if(atr <= 0.0)
     {
      // ATR が 0 付近だと比率計算が不安定になるため、その場合は更新を見送る
      LogPrint("WARN", "REGIME", "OnNewBarH1: ATR_H1 が 0 以下のためレジーム更新をスキップします。");
      return;
     }

   double ma_diff_atr_ratio = MathAbs(ma_diff) / atr;

   int    new_regime    = m_regime;
   double new_trend_dir = 0.0;

   //--- トレンド判定：ADX がそこそこ強く、MA差もATRに対して十分大きい
   if(adx >= InpTrend_ADX_Min && ma_diff_atr_ratio >= InpTrend_MA_ATR_DiffMin)
     {
      new_regime    = REGIME_TREND;
      new_trend_dir = (ma_diff > 0.0 ? 1.0 : -1.0); // MA_fast > MA_slow なら上昇トレンド、逆なら下降トレンド
     }
   //--- レンジ判定：ADX が弱く、MA差もATRに対して小さい
   else if(adx <= InpRange_ADX_Max && ma_diff_atr_ratio <= InpRange_MA_ATR_DiffMax)
     {
      new_regime    = REGIME_RANGE;
      new_trend_dir = 0.0; // レンジ中は方向性 0
     }
   //--- それ以外はカオス（移行期や急変動など）
   else
     {
      new_regime    = REGIME_CHAOS;
      new_trend_dir = 0.0;
     }

   // レジーム or トレンド方向に変化があった場合だけ更新＋ログ
   if(new_regime != m_regime || new_trend_dir != m_trend_dir)
     {
      m_regime           = new_regime;
      m_trend_dir        = new_trend_dir;
      m_last_change_time = TimeCurrent(); // 実際には H1 バーの確定時間でも良いが、ここでは現在時刻で代用

      string regime_name = "UNKNOWN";
      if(m_regime == REGIME_TREND)
         regime_name = "TREND";
      else if(m_regime == REGIME_RANGE)
         regime_name = "RANGE";
      else if(m_regime == REGIME_CHAOS)
         regime_name = "CHAOS";

      string dir_text = "0";
      if(m_trend_dir > 0.0)
         dir_text = "UP";
      else if(m_trend_dir < 0.0)
         dir_text = "DOWN";

      LogPrint("INFO", "REGIME",
               StringFormat("H1 レジーム更新: Regime=%s, TrendDir=%s, ADX=%.2f, MA_Diff_ATR_Ratio=%.2f",
                            regime_name, dir_text, adx, ma_diff_atr_ratio));
     }
  }


//--- レジーム変更直後のクールダウン中かどうか
bool CRegimeEngine::InCooldown() const
  {
   // レジーム変更直後にエントリを控えるためのクールダウン判定。
   // 「最後にレジームが変化した H1 バー」から何本経過したかで判断する。
   if(m_last_change_time==0)
      return(false);

   // クールダウンバー数が 0 以下ならクールダウン無効
   if(InpRegimeCooldownBars_H1 <= 0)
      return(false);

   // iBarShift を使い、レジーム変更時刻と現在時刻に対応する H1 バーのインデックス差を取る
   int shift_change = iBarShift(_Symbol, PERIOD_H1, m_last_change_time, true);
   int shift_now    = iBarShift(_Symbol, PERIOD_H1, TimeCurrent(),      true);

   if(shift_change < 0 || shift_now < 0)
      return(false);

   // shift は「0 が最新バー」で、数字が大きいほど過去になる。
   // 例: 直近バー=0, 1本前=1 ...
   int bars_diff = shift_change - shift_now; // レジーム変更バーから何本経過したか

   // 直近 InpRegimeCooldownBars_H1 本の間はクールダウン扱い
   if(bars_diff < InpRegimeCooldownBars_H1)
      return(true);

   return(false);
  }


//==================================================================
// CStateTracker : 日次・週次DDやFOMOなど状態管理（骨格）
//==================================================================
class CStateTracker
  {
private:
   //--- 1 日単位の損益とドローダウンを追跡するための累積値
   double   m_daily_pl;       // 1 日の損益合計（JPY）。日次リセット時に 0 に戻る
   double   m_daily_dd;       // 1 日内でのドローダウン（負の累積額）。日次リセット時に 0 に戻る
   datetime m_daily_start;    // 日次計測の開始日時（現地時間の 0:00 を保持）

   //--- 1 週間単位の損益とドローダウンを追跡するための累積値
   double   m_weekly_pl;      // 1 週間の損益合計（JPY）。週次リセット時に 0 に戻る
   double   m_weekly_dd;      // 1 週間内でのドローダウン（負の累積額）。週次リセット時に 0 に戻る
   datetime m_weekly_start;   // 週次計測の開始日時（週の初日 0:00 を保持）

   //--- FOMO（Fear of Missing Out）対策用の監視情報
   // 現時点では指標が未確定なため、必要最小限のコメントのみを残す。
   // 実際の監視ロジックを追加する際にフィールドを拡張する。

public:
                     CStateTracker();
   void              Init();
   void              OnNewDay();
   void              OnNewWeek();
   void              AddTradeResult(double pl);
   double            DailyDD() const { return m_daily_dd; }
   double            WeeklyDD() const{ return m_weekly_dd; }
  };

//--- コンストラクタ
CStateTracker::CStateTracker()
  {
   m_daily_pl     = 0.0;
   m_daily_dd     = 0.0;
   m_daily_start  = 0;
   m_weekly_pl    = 0.0;
   m_weekly_dd    = 0.0;
   m_weekly_start = 0;
  }

void CStateTracker::Init()
  {
   // 現在時刻を基準に日次・週次の計測開始時刻を設定
   // 日次: 当日の 0:00、週次: 直近の月曜 0:00
   m_daily_start  = DateOfDay(TimeCurrent());
   m_weekly_start = WeekStartMonday(TimeCurrent());
   LogPrint("INFO", "STATE", "CStateTracker::Init called");
  }

void CStateTracker::OnNewDay()
  {
   // 日次リセット: 損益・DDをクリアし、開始日時を更新する
   m_daily_pl    = 0.0;
   m_daily_dd    = 0.0;
   m_daily_start = DateOfDay(TimeCurrent());
   LogPrint("INFO", "STATE", "New day started");
  }

void CStateTracker::OnNewWeek()
  {
   // 週次リセット: 損益・DDをクリアし、開始日時を週初に合わせる
   m_weekly_pl    = 0.0;
   m_weekly_dd    = 0.0;
   m_weekly_start = WeekStartMonday(TimeCurrent());
   LogPrint("INFO", "STATE", "New week started");
  }

void CStateTracker::AddTradeResult(double pl)
  {
   // 取引結果の損益を日次・週次累計へ反映し、ドローダウンも更新する
   // pl は通貨ベースの損益（負値で損失）を想定
   m_daily_pl  += pl;
   m_weekly_pl += pl;

   // 日次DD: 日次損益が過去最小値を更新した場合に反映（0 以上のときは 0 に戻す）
   m_daily_dd = MathMin(m_daily_dd, m_daily_pl);
   if(m_daily_dd > 0.0)
      m_daily_dd = 0.0;

   // 週次DD: 週次損益が過去最小値を更新した場合に反映（0 以上のときは 0 に戻す）
   m_weekly_dd = MathMin(m_weekly_dd, m_weekly_pl);
   if(m_weekly_dd > 0.0)
      m_weekly_dd = 0.0;
  }

//==================================================================
// CGlobalGate : 時間帯・スプレッド・DD・ニュース・クールダウン等の共通フィルタ（骨格）
//==================================================================
class CGlobalGate
  {
 private:
    CRegimeEngine *m_regime_engine;
    CStateTracker *m_state_tracker;

 public:
                      CGlobalGate();
    //--- 外部で生成されたレジームエンジンと状態管理インスタンスを紐付ける
    //     ポインタを直接受け取るよりも、参照経由で受けてから安全にアドレスを保持する方が
    //     誤った引数（null など）をコンパイル時に早期検出できるため、引数は参照で受ける
    void              Attach(CRegimeEngine &reg, CStateTracker &state);
    bool              CanOpen(); // 新規エントリ可能か？
  };

CGlobalGate::CGlobalGate()
   {
    //--- 初期状態では未接続として明示的に NULL を設定しておく
    m_regime_engine = NULL;
    m_state_tracker = NULL;
   }

void CGlobalGate::Attach(CRegimeEngine &reg, CStateTracker &state)
   {
    //--- 参照で受け取った外部オブジェクトのアドレスを保持する
    //     ここでは単にアドレスを保存するだけで、null チェックは CanOpen 内で行う
    m_regime_engine = &reg;
    m_state_tracker = &state;
   }

//------------------------------------------------------------------
// CGlobalGate::CanOpen
//  - 新規エントリをしてよい状況かどうかを判定する
//  - 時間帯 / DD / スプレッド / ATR 比 / レジームクールダウン / ニュース などをまとめてチェック
//------------------------------------------------------------------
bool CGlobalGate::CanOpen()
  {
   //================================================================
   // 0) Spread/ATR ログ間引き用の static 変数
   //================================================================
   static bool     last_spread_atr_block    = false; // 直近判定で Spread/ATR が NG だったか
   static datetime last_spread_atr_log_time = 0;     // 最後に NG ログを出した時刻
   const  int      SPREAD_ATR_LOG_INTERVAL_SEC = 60; // NG 継続中にログを出す最小間隔[秒]

   //================================================================
   // 1) モジュールのアタッチ状態チェック
   //================================================================
   if(m_regime_engine == NULL || m_state_tracker == NULL)
     {
      LogPrint("ERROR", "GATE", "CanOpen: RegimeEngine または StateTracker が未アタッチです。");
      return(false);
     }
    //--- 上記で null チェックを終えたので、以降はポインタをローカルへキャッシュする
    //    ・MQL5 ではローカル変数への参照型束縛がサポートされておらず、& を使うと
    //      「reference cannot used」のコンパイルエラーになるため、素直にポインタで扱う
    //    ・state という名前が他の識別子と紛らわしくならないよう、末尾に _ptr を付けて
    //      「ポインタである」ことを明示し、後続の利用箇所で型推論の誤解を避ける
    CRegimeEngine *regime_ptr = m_regime_engine;
    CStateTracker *state_ptr  = m_state_tracker;

   //================================================================
   // 2) 取引時間帯フィルタ
   //================================================================
   MqlDateTime mt;
   TimeToStruct(TimeCurrent(), mt);
   int hour = mt.hour;

   bool time_ok = false;
   if(InpTradeStartHour == InpTradeEndHour)
     {
      // 同じ値の場合は「24時間許可」
      time_ok = true;
     }
   else if(InpTradeStartHour < InpTradeEndHour)
     {
      // 同一日内に収まるパターン
      time_ok = (hour >= InpTradeStartHour && hour < InpTradeEndHour);
     }
   else
     {
      // 日またぎパターン（例: 16～3 時）
      time_ok = (hour >= InpTradeStartHour || hour < InpTradeEndHour);
     }

   if(!time_ok)
      return(false);

   //================================================================
   // 3) 日次 / 週次ドローダウンチェック
   //================================================================
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance > 0.0)
      {
       //--- 現在の DD を一旦 JPY ベースで取り出し、型が曖昧にならないよう明示的な一時変数で保持
       //    （ポインタ経由の戻り値を直接 MathAbs に渡すと、メタエディタの解析で
       //     「ポインタを数値に変換できない」と誤解されることがあるため、
       //     手順を分解して可読性と安全性を上げる）
       //    ポインタのままでは "->" が続き読みにくいので、上で短縮名にしたポインタを
       //    介してシンプルに呼び出す（null チェック済みなので即時呼び出しで安全）
       // MQL5 ではクラスポインタ経由でも "." でメソッドを呼び出す（"->" はサポート外）ため、
       // ここではポインタ名をそのまま用いて DailyDD / WeeklyDD を取得する。
       double daily_dd_jpy  = state_ptr.DailyDD();
       double weekly_dd_jpy = state_ptr.WeeklyDD();

       //--- 口座残高に対する割合（%）を算出
       double daily_dd_pct  = 100.0 * MathAbs(daily_dd_jpy)  / balance;
       double weekly_dd_pct = 100.0 * MathAbs(weekly_dd_jpy) / balance;

       //--- 閾値超過なら即座にエントリを禁止し、具体的な比率をログ出力
       if(daily_dd_pct >= InpMaxDailyDD || weekly_dd_pct >= InpMaxWeeklyDD)
         {
          LogPrint("WARN", "GATE",
                   StringFormat("CanOpen: DD 超過によりエントリ禁止 (DailyDD=%.2f%%, WeeklyDD=%.2f%%)",
                                daily_dd_pct, weekly_dd_pct));
          return(false);
         }
      }

   //================================================================
   // 4) スプレッド / ATR_M1 チェック
   //================================================================
   long spread_points = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SPREAD, spread_points))
     {
      LogPrint("ERROR", "GATE", "CanOpen: SYMBOL_SPREAD が取得できません。");
      return(false);
     }

   double point    = _Point;
   double pip_size = (_Digits == 3 || _Digits == 5) ? (10.0 * point) : point; // 3/5桁は Point×10 が1pip
   double spread_pips = (double)spread_points * point / pip_size;

   if(spread_pips <= 0.0)
     {
      LogPrint("WARN", "GATE", "CanOpen: スプレッドが 0 以下のためエントリをスキップします。");
      return(false);
     }

   // 絶対スプレッド上限
   if(spread_pips > InpMaxSpreadPips)
     {
      //LogPrint("INFO", "GATE",
      //         StringFormat("CanOpen: スプレッドが上限を超過 (Spread=%.2f pips, Max=%.2f pips)",
      //                      spread_pips, InpMaxSpreadPips));
      return(false);
     }

   // Spread / ATR_M1 比チェック
   if(InpMaxSpreadATRRatio > 0.0 && g_handle_atr_m1 != INVALID_HANDLE)
     {
      double atr_buf[1];
      if(CopyBuffer(g_handle_atr_m1, 0, 1, 1, atr_buf) == 1)
        {
         double atr_m1      = atr_buf[0];                    // 価格単位
         double atr_m1_pips = (atr_m1 > 0.0 ? atr_m1 / pip_size : 0.0);

         if(atr_m1_pips > 0.0)
           {
            double ratio = spread_pips / atr_m1_pips;

            if(ratio > InpMaxSpreadATRRatio)
              {
               bool should_log = false;

               // 状態が OK→NG に変わった瞬間は必ずログ
               if(!last_spread_atr_block)
                  should_log = true;
               // NG 継続中は一定秒数ごとにだけログ
               else if(TimeCurrent() - last_spread_atr_log_time >= SPREAD_ATR_LOG_INTERVAL_SEC)
                  should_log = true;

                 if(should_log)
                   {
                    // ロングメッセージが複数行にまたがってシンタックスエラーにならないよう、1 行で整形する
                    LogPrint("INFO", "GATE",
                             StringFormat("CanOpen: Spread/ATR 比が上限を超過 (Spread=%.2f pips, ATR_M1=%.2f pips, Ratio=%.2f, Max=%.2f)",
                                          spread_pips, atr_m1_pips, ratio, InpMaxSpreadATRRatio));
                    LogPrint("INFO", "TEST",
                              StringFormat("spread_points=%ld, pip_size=%.5f, spread_pips=%.3f, ATR_M1=%.5f, ATR_M1_pips=%.3f, ratio=%.3f, Max=%.3f",
                                          spread_points, pip_size, spread_pips, atr_m1, atr_m1_pips, ratio, InpMaxSpreadATRRatio));

                    last_spread_atr_log_time = TimeCurrent();
                   }

               last_spread_atr_block = true;
               return(false);
              }
            else
              {
               // 今回は Spread/ATR OK。直前までNGだったなら復帰ログを一回だけ出す
               if(last_spread_atr_block)
                 {
                  LogPrint("INFO", "GATE",
                           StringFormat("CanOpen: Spread/ATR 比が閾値内に復帰 (Spread=%.2f pips, ATR_M1=%.2f pips, Ratio=%.2f, Max=%.2f)",
                                        spread_pips, atr_m1_pips, ratio, InpMaxSpreadATRRatio));
                 }
               last_spread_atr_block = false;
              }
           }
        }
     }

   //================================================================
   // 5) レジームクールダウン
   //================================================================
   //--- レジームエンジンのクールダウン状態を確認
   //    ポインタ経由で呼び出すことで、参照束縛禁止によるコンパイルエラーを回避
   // MQL5 のポインタ呼び出しは "." を用いる点に注意（"->" ではコンパイル不可）。
    if(regime_ptr.InCooldown())
     {
      return(false);
     }

   //================================================================
   // 6) ニュースフィルタ（まだダミー）
   //================================================================
   if(InpUseNewsFilter)
     {
      // TODO: ニュース時間帯の取得ロジックをここに実装
      // 現時点では挙動を変えない（ログも控える）
     }

   //================================================================
   // 7) ここまで全ての条件をパスした場合のみ、新規エントリ許可
   //================================================================
   return(true);
  }


//==================================================================
// 各アルファクラスの骨格定義
//==================================================================

//--------------------------------------------------------------
// CAlphaA : 圧縮ブレイク順張り
//  - H1 がトレンド状態のときのみエントリ
//  - M5 の一定本数が「狭いレンジ＋インサイドバー多め」なら圧縮とみなす
//  - 圧縮状態から抜けたタイミングで、トレンド方向へブレイクしたらエントリ
//--------------------------------------------------------------
class CAlphaA
  {
private:
   int         m_magic;              // このアルファ専用のマジック番号

   // M5 ATR 用ハンドル
   int         m_handle_atr_m5;
   double      m_last_atr_m5;

   // 圧縮状態の管理
   bool        m_in_compression;     // 直近が圧縮状態かどうか
   double      m_range_high;         // 圧縮レンジの高値
   double      m_range_low;          // 圧縮レンジの安値

   // シグナルの一時保管（OnNewBarM5 で作って GetSignal で受け取る）
   bool        m_has_pending_signal;
   TradeSignal m_pending_signal;

public:
                     CAlphaA(int magic_base);
   void              Init();
   void              OnNewBarM5();                 // M5新バー時に状態更新＆シグナル生成
   bool              GetSignal(TradeSignal &sig);  // 保留シグナルを1回だけ返す
  };

CAlphaA::CAlphaA(int magic_base)
  {
   m_magic             = magic_base + 1; // AlphaA用のマジック番号
   m_handle_atr_m5     = INVALID_HANDLE;
   m_last_atr_m5       = 0.0;
   m_in_compression    = false;
   m_range_high        = 0.0;
   m_range_low         = 0.0;
   m_has_pending_signal = false;
   ZeroMemory(m_pending_signal);
  }

void CAlphaA::Init()
  {
   // M5 ATR ハンドルを生成（圧縮判定・SL/TP距離計算に使う）
   m_handle_atr_m5 = iATR(_Symbol, PERIOD_M5, 14);
   if(m_handle_atr_m5 == INVALID_HANDLE)
     {
      LogPrint("ERROR", "ALPHA_A", "Init: M5 ATR ハンドル作成に失敗しました。");
     }
   else
     {
      LogPrint("INFO", "ALPHA_A", "Init: M5 ATR ハンドル作成完了。");
     }
  }

void CAlphaA::OnNewBarM5()
  {
   //--- 必要な履歴が足りなければ何もしない
   int lookback = InpA_Lookback_M5;
   if(lookback <= 2)
      return;

   int bars_m5 = Bars(_Symbol, PERIOD_M5);
   if(bars_m5 <= lookback + 2) // 多少余裕を見ておく
      return;

   //--- ATR取得
   if(m_handle_atr_m5 == INVALID_HANDLE)
     {
      LogPrint("WARN", "ALPHA_A", "OnNewBarM5: ATR_M5 ハンドル未初期化のため処理をスキップします。");
      return;
     }

   double atr_buf[1];
   if(CopyBuffer(m_handle_atr_m5, 0, 1, 1, atr_buf) != 1)
     {
      LogPrint("WARN", "ALPHA_A", "OnNewBarM5: ATR_M5 CopyBuffer に失敗しました。");
      return;
     }

   double atr_m5 = atr_buf[0];
   if(atr_m5 <= 0.0)
      return;

   // 前回値を控えておく（ブレイク判定で「直前ATR」を使うため）
   double prev_atr        = m_last_atr_m5;
   m_last_atr_m5          = atr_m5;
   bool   was_compress    = m_in_compression;
   double prev_range_high = m_range_high;
   double prev_range_low  = m_range_low;

   //--- 現在の lookback 本の高値・安値レンジを計算（shift=1 が確定済み最新バー）
   double max_high = -DBL_MAX;
   double min_low  =  DBL_MAX;

   for(int shift = 1; shift <= lookback; ++shift)
     {
      double h = iHigh(_Symbol, PERIOD_M5, shift);
      double l = iLow(_Symbol, PERIOD_M5, shift);
      if(h == 0.0 && l == 0.0)
         return; // データ不整合時は何もしない

      if(h > max_high) max_high = h;
      if(l < min_low)  min_low  = l;
     }

   double price_range = max_high - min_low;
   if(price_range <= 0.0)
     {
      m_in_compression = false;
      return;
     }

   double range_atr_ratio = price_range / atr_m5;

   //--- インサイドバー率をざっくり測る
   int inside_count   = 0;
   int inside_samples = lookback - 1; // 前のバーと比較する本数

   for(int shift = 1; shift <= lookback - 1; ++shift)
     {
      double h      = iHigh(_Symbol, PERIOD_M5, shift);
      double l      = iLow(_Symbol, PERIOD_M5, shift);
      double h_prev = iHigh(_Symbol, PERIOD_M5, shift + 1);
      double l_prev = iLow(_Symbol, PERIOD_M5, shift + 1);

      if(h <= h_prev && l >= l_prev)
         inside_count++;
     }

   double inside_rate = 0.0;
   if(inside_samples > 0)
      inside_rate = (double)inside_count / (double)inside_samples;

   //--- 現在のバー群が「圧縮状態」かどうか
   bool now_compress = false;
   if(range_atr_ratio <= InpA_Range_ATR_Ratio_Max &&
      inside_rate     >= InpA_InsideRateMin)
     {
      now_compress = true;
     }

   // 圧縮状態を更新
   m_in_compression = now_compress;
   if(now_compress)
     {
      m_range_high = max_high;
      m_range_low  = min_low;

      // 新しく圧縮状態に入ったタイミングでログを 1 回だけ出す
      if(!was_compress)
        {
         LogPrint("INFO", "ALPHA_A",
                  StringFormat("Enter compression: range_atr_ratio=%.2f, inside_rate=%.2f, high=%.5f, low=%.5f, ATR_M5=%.5f, lookback=%d",
                               range_atr_ratio, inside_rate, max_high, min_low, atr_m5, lookback));
        }
     }

   // このバーでのブレイクアウト判定は、
   // 「直前まで圧縮だったのに、今回の窓では圧縮条件を満たさなくなった」
   if(!(was_compress && !now_compress))
      return;

   // ここに来た時点で「圧縮 → 非圧縮」への遷移が起きている
   // → ブレイク候補として詳細ログを出す
   LogPrint("INFO", "ALPHA_A",
            StringFormat("Leave compression: prev_high=%.5f, prev_low=%.5f, range_atr_ratio=%.2f, inside_rate=%.2f",
                         prev_range_high, prev_range_low, range_atr_ratio, inside_rate));

   //--- H1レジームがトレンド状態でない場合はエントリしない
   int    regime    = g_regime.Regime();
   double trend_dir = g_regime.TrendDir();
   if(regime != REGIME_TREND || trend_dir == 0.0)
     {
      LogPrint("INFO", "ALPHA_A",
               StringFormat("Skip breakout: Regime=%d, TrendDir=%.1f", regime, trend_dir));
      return;
     }

   //--- ブレイク判定に使うのは直近確定M5バーの終値
   double last_close = iClose(_Symbol, PERIOD_M5, 1);
   if(last_close <= 0.0)
      return;

   //--- エントリ価格の目安には直近ATR（なければ今回のATR）を使う
   double atr_for_entry = (prev_atr > 0.0 ? prev_atr : atr_m5);
   if(atr_for_entry <= 0.0)
      return;

   double offset = InpA_EntryOffsetATR * atr_for_entry;

   // デバッグ用：ブレイク条件チェックの時点の状況をログ
   LogPrint("INFO", "ALPHA_A",
            StringFormat("Breakout check: close=%.5f, prev_high=%.5f, prev_low=%.5f, offset=%.5f, ATR_entry=%.5f, trend_dir=%.1f",
                         last_close, prev_range_high, prev_range_low, offset, atr_for_entry, trend_dir));

   TradeSignal sig;
   ZeroMemory(sig);
   sig.is_valid = false;

   // 上昇トレンドでボックス上抜け
   if(trend_dir > 0.0 && last_close > (prev_range_high + offset))
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(entry <= 0.0)
         entry = last_close;

      double sl = entry - InpA_SL_ATR * atr_for_entry;
      double tp = entry + InpA_TP1_ATR * atr_for_entry;

      sig.is_valid = true;
      sig.side     = SIGNAL_BUY;
      sig.price    = 0.0;     // 0.0 は「成行」を意味する（実際の価格はRiskManager側で取得）
      sig.sl       = sl;
      sig.tp       = tp;
      sig.magic    = m_magic;
      sig.comment  = "A:BreakoutBuy";
     }
   // 下降トレンドでボックス下抜け
   else if(trend_dir < 0.0 && last_close < (prev_range_low - offset))
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(entry <= 0.0)
         entry = last_close;

      double sl = entry + InpA_SL_ATR * atr_for_entry;
      double tp = entry - InpA_TP1_ATR * atr_for_entry;

      sig.is_valid = true;
      sig.side     = SIGNAL_SELL;
      sig.price    = 0.0;     // 成行
      sig.sl       = sl;
      sig.tp       = tp;
      sig.magic    = m_magic;
      sig.comment  = "A:BreakoutSell";
     }
   else
     {
      // 圧縮は解けたが、トレンド方向にブレイクしなかった場合
      LogPrint("INFO", "ALPHA_A",
               "Compression ended but no trend-direction breakout (conditions not met).");
     }

   if(sig.is_valid)
     {
      m_pending_signal     = sig;
      m_has_pending_signal = true;

      LogPrint("INFO", "ALPHA_A",
               StringFormat("Breakout signal: side=%s, close=%.5f, SL=%.5f, TP=%.5f, ATR_M5=%.5f",
                            (sig.side == SIGNAL_BUY ? "BUY" : "SELL"),
                            last_close, sig.sl, sig.tp, atr_for_entry));
     }
  }


bool CAlphaA::GetSignal(TradeSignal &sig)
  {
   // OnNewBarM5 で作ったシグナルを 1 回だけ返す
   if(!m_has_pending_signal)
     {
      sig.is_valid = false;
      return(false);
     }

   sig = m_pending_signal; // 構造体コピー
   m_has_pending_signal = false;
   return(true);
  }


//--------------------------------------------------------------
// CAlphaB : AVWAP回帰逆張り
//--------------------------------------------------------------
class CAlphaB
  {
private:
   int      m_magic;
public:
                     CAlphaB(int magic_base);
   void              Init();
   void              OnNewBarM5();
   bool              GetSignal(TradeSignal &sig);
  };

CAlphaB::CAlphaB(int magic_base)
  {
   m_magic = magic_base + 2;
  }

void CAlphaB::Init()
  {
   LogPrint("INFO", "ALPHA_B", "Init called");
  }

void CAlphaB::OnNewBarM5()
  {
   // TODO: AVWAP近似計算・乖離状態の更新など
  }

bool CAlphaB::GetSignal(TradeSignal &sig)
  {
   sig.is_valid = false;
   return(false);
  }

//--------------------------------------------------------------
// CAlphaC : ミニスイング刈り取り
//--------------------------------------------------------------
class CAlphaC
  {
private:
   int      m_magic;
public:
                     CAlphaC(int magic_base);
   void              Init();
   void              OnNewBarM1();
   bool              GetSignal(TradeSignal &sig);
  };

CAlphaC::CAlphaC(int magic_base)
  {
   m_magic = magic_base + 3;
  }

void CAlphaC::Init()
  {
   LogPrint("INFO", "ALPHA_C", "Init called");
  }

void CAlphaC::OnNewBarM1()
  {
   // TODO: 高値安値の履歴を更新し、スイング向きの変化を検出
  }

bool CAlphaC::GetSignal(TradeSignal &sig)
  {
   sig.is_valid = false;
   return(false);
  }

//==================================================================
// CRiskManager : ロット計算とシグナル選別（骨格）
//==================================================================
class CRiskManager
  {
private:
   CTrade   m_trade;

public:
                     CRiskManager();
   void              Init();
   double            CalcLotByRisk(double sl_pips);
   bool              Execute(TradeSignal &sig_a,
                             TradeSignal &sig_b,
                             TradeSignal &sig_c);
  };

CRiskManager::CRiskManager()
  {
  }

void CRiskManager::Init()
  {
   LogPrint("INFO", "RISK", "Init called");
  }

//--- リスク[%]とSL幅[pips]からロットを計算（本実装）
//    - 口座残高 × InpRiskPerTrade[%] = 許容損失額
//    - TickValue / TickSize から「1ロットあたり1pipの金額」を求める
//    - SL[pips] × 1pipあたり金額 ＝ 1ロットあたり損失額
//    - 許容損失額 / 1ロット損失額 ＝ ロット数
double CRiskManager::CalcLotByRisk(double sl_pips)
  {
   if(sl_pips <= 0.0)
      return(0.0);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return(0.0);

   double risk_amt = balance * InpRiskPerTrade / 100.0;

   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double volume_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volume_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double point    = _Point;
   double pip_size = (_Digits == 3 || _Digits == 5) ? (10.0 * point) : point;

   if(tick_size <= 0.0 || tick_value <= 0.0 || pip_size <= 0.0 || volume_step <= 0.0)
      return(0.0);

   // 1ロットあたり1pipの金額
   double pip_value_1lot = tick_value * (pip_size / tick_size);
   if(pip_value_1lot <= 0.0)
      return(0.0);

   double loss_per_lot = sl_pips * pip_value_1lot;
   if(loss_per_lot <= 0.0)
      return(0.0);

   double lots = risk_amt / loss_per_lot;

   //--- ブローカーの制約に合わせてクリップ＆ステップ補正
   if(volume_min > 0.0 && lots < volume_min)
      lots = volume_min;
   if(volume_max > 0.0 && lots > volume_max)
      lots = volume_max;

   lots = MathFloor(lots / volume_step) * volume_step;
   if(lots < volume_min)
      return(0.0);

   return(lots);
  }


//--- 各Alphaのシグナルを受け取り、どれを実行するか決めて注文発行
//    Phase1では優先順位：A > B > C で、1つだけ実行。
//    かつ、このEA（MagicBase+1〜3）のポジションが既にある場合は新規エントリしない。
bool CRiskManager::Execute(TradeSignal &sig_a,
                           TradeSignal &sig_b,
                           TradeSignal &sig_c)
  {
   //================================================================
   // 1) シグナル選択（優先順位：A > B > C）
   //================================================================
   TradeSignal sig;
   ZeroMemory(sig);
   sig.is_valid = false;

   if(sig_a.is_valid)
      sig = sig_a;
   else if(sig_b.is_valid)
      sig = sig_b;
   else if(sig_c.is_valid)
      sig = sig_c;
   else
      return(false); // シグナルが何もなければ何もしない

   //================================================================
   // 2) このEAのポジションが既にある場合は新規エントリ禁止
   //    - Magic: InpMagicBase+1 ～ InpMagicBase+3 をこのEAの範囲とみなす
   //================================================================
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   magic = (long)PositionGetInteger(POSITION_MAGIC);

      if(sym == _Symbol && magic >= InpMagicBase + 1 && magic <= InpMagicBase + 3)
        {
         // すでにこのEAのポジションがある → 新規エントリは見送る
         return(false);
        }
     }

   //================================================================
   // 3) エントリー価格・SL/TP距離の計算
   //================================================================
   double point    = _Point;
   double pip_size = (_Digits == 3 || _Digits == 5) ? (10.0 * point) : point;

   double entry_price = 0.0;
   if(sig.side == SIGNAL_BUY)
      entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else if(sig.side == SIGNAL_SELL)
      entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      return(false);

   if(entry_price <= 0.0)
      return(false);

   double sl_price = sig.sl;
   double tp_price = sig.tp;

   if(sl_price <= 0.0 || tp_price <= 0.0)
      return(false);

   double sl_pips = MathAbs(entry_price - sl_price) / pip_size;
   double tp_pips = MathAbs(tp_price - entry_price) / pip_size;

   if(sl_pips <= 0.0 || tp_pips <= 0.0)
      return(false);

   //================================================================
   // 4) TP / Spread 比が低すぎるエントリはスキップ
   //================================================================
   long spread_points = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SPREAD, spread_points))
      return(false);

   double spread_pips = (double)spread_points * point / pip_size;

   if(spread_pips > 0.0)
     {
      double target_spread_ratio = tp_pips / spread_pips;
      if(target_spread_ratio < InpMinTargetToSpreadRatio)
        {
         LogPrint("INFO", "RISK",
                  StringFormat("Execute: TP/Spread 比が小さすぎるためエントリ見送り (TP=%.2f pips, Spread=%.2f pips, Ratio=%.2f, Min=%.2f)",
                               tp_pips, spread_pips, target_spread_ratio, InpMinTargetToSpreadRatio));
         return(false);
        }
     }

   //================================================================
   // 5) ロット計算
   //================================================================
   double lots = CalcLotByRisk(sl_pips);
   if(lots <= 0.0)
     {
      LogPrint("WARN", "RISK",
               StringFormat("Execute: CalcLotByRisk によりロット=%.2f のためエントリ見送り (SL=%.2f pips)",
                            lots, sl_pips));
      return(false);
     }

   //================================================================
   // 6) 実際の注文発行
   //================================================================
   m_trade.SetExpertMagicNumber(sig.magic);

   bool   result    = false;
   string side_text = (sig.side == SIGNAL_BUY ? "BUY" : "SELL");

   if(sig.side == SIGNAL_BUY)
     {
      result = m_trade.Buy(lots, _Symbol, 0.0, sl_price, tp_price, sig.comment);
     }
   else if(sig.side == SIGNAL_SELL)
     {
      result = m_trade.Sell(lots, _Symbol, 0.0, sl_price, tp_price, sig.comment);
     }

   if(!result)
     {
      int err = GetLastError();
      LogPrint("ERROR", "RISK",
               StringFormat("Execute: 注文失敗 side=%s lots=%.2f err=%d", side_text, lots, err));
      return(false);
     }

   LogPrint("INFO", "RISK",
            StringFormat("Execute: 注文成功 side=%s lots=%.2f SL=%.3f TP=%.3f",
                         side_text, lots, sl_price, tp_price));
   return(true);
  }


//==================================================================
// グローバルインスタンス
//==================================================================
CRegimeEngine g_regime;
CStateTracker g_state;
CGlobalGate   g_gate;
CAlphaA       g_alpha_a(InpMagicBase);
CAlphaB       g_alpha_b(InpMagicBase);
CAlphaC       g_alpha_c(InpMagicBase);
CRiskManager  g_risk;

//--- M1 ATR 用インジケータハンドル（スプレッド/ATR 比チェックで使用）
int      g_handle_atr_m1 = INVALID_HANDLE;

//--- バー更新検出用
datetime g_last_time_h1 = 0;
datetime g_last_time_m5 = 0;
datetime g_last_time_m1 = 0;

//==================================================================
// ヘルパー関数：新バー判定
//==================================================================

//--- 指定タイムフレームで新バーが確定したかどうかを判定する簡易関数
bool IsNewBar(const ENUM_TIMEFRAMES tf, datetime &last_time)
  {
   datetime current = iTime(_Symbol, tf, 0);
   if(current != 0 && current != last_time)
     {
      last_time = current;
      return(true);
     }
   return(false);
  }

//==================================================================
// OnInit / OnDeinit / OnTick
//==================================================================

//+------------------------------------------------------------------+
int OnInit()
  {
   LogPrint("INFO", "INIT", "RAIN_Delta_EA_Phase1 OnInit start");

   //--- M1 ATR インジケータハンドルを生成（Spread/ATR フィルタ用）
   //     ここでは period=14 の ATR を使用し、確定バーのボラティリティとして参照する。
   g_handle_atr_m1 = iATR(_Symbol, PERIOD_M1, 14);
   if(g_handle_atr_m1 == INVALID_HANDLE)
     {
      LogPrint("ERROR", "INIT", "M1 ATR ハンドルの作成に失敗しました。Spread/ATR フィルタは無効になります。");
     }
   else
     {
      LogPrint("INFO", "INIT", "M1 ATR ハンドル作成完了。");
     }

   //--- 各モジュール初期化
   g_regime.Init();
   g_state.Init();

   // Attach は参照受け取りなので、生ポインタではなくオブジェクトそのものを渡す
   // （& を付けると CRegimeEngine* 型となりシグネチャ不一致でコンパイルエラーとなる）
   g_gate.Attach(g_regime, g_state);

   g_alpha_a.Init();
   g_alpha_b.Init();
   g_alpha_c.Init();

   g_risk.Init();

   LogPrint("INFO", "INIT", "OnInit completed");
   return(INIT_SUCCEEDED);
  }


//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // M1 ATR ハンドルを明示的に解放しておく（バックテスト・最適化時のリソースリーク防止）
   if(g_handle_atr_m1 != INVALID_HANDLE)
     {
      IndicatorRelease(g_handle_atr_m1);
      g_handle_atr_m1 = INVALID_HANDLE;
     }

   LogPrint("INFO", "DEINIT", "EA deinitialized");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- 新バー判定
   bool new_h1 = IsNewBar(PERIOD_H1, g_last_time_h1);
   bool new_m5 = IsNewBar(PERIOD_M5, g_last_time_m5);
   bool new_m1 = IsNewBar(PERIOD_M1, g_last_time_m1);

   //--- H1新バー → レジーム更新
   if(new_h1)
      g_regime.OnNewBarH1();

   // H1 新バー時だけデバッグログを出す（テスト用）
   if(new_h1)
     {
      datetime d = DateOfDay(TimeCurrent());
      datetime w = WeekStartMonday(TimeCurrent());
   
      LogPrint("INFO", "TEST",
               StringFormat("Now=%s, DateOfDay=%s, WeekStart=%s",
                            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                            TimeToString(d, TIME_DATE|TIME_SECONDS),
                            TimeToString(w, TIME_DATE|TIME_SECONDS)));
     }

   //--- M5新バー → AlphaA / AlphaB の状態更新
   if(new_m5)
     {
      g_alpha_a.OnNewBarM5();
      g_alpha_b.OnNewBarM5();
     }

   //--- M1新バー → AlphaC の状態更新
   if(new_m1)
     {
      g_alpha_c.OnNewBarM1();
     }

   //--- 新規エントリ可能かの共通チェック
   if(!g_gate.CanOpen())
      return;

   //--- 各Alphaからシグナルを取得（現時点では常に無効）
   TradeSignal sig_a, sig_b, sig_c;
   sig_a.is_valid = false;
   sig_b.is_valid = false;
   sig_c.is_valid = false;

   g_alpha_a.GetSignal(sig_a);
   g_alpha_b.GetSignal(sig_b);
   g_alpha_c.GetSignal(sig_c);

   //--- リスクマネージャに渡して、発注可否・内容を決定
   g_risk.Execute(sig_a, sig_b, sig_c);
  }
//+------------------------------------------------------------------+
