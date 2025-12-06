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
input double InpA_Range_ATR_Ratio_Max = 0.8;
input double InpA_InsideRateMin     = 0.5;
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
   // - EMA(終値) 2 本でトレンド方向と傾きの強さを確認
   // - ADX でトレンドの強さを確認
   // - ATR でボラティリティを正規化して MA 差との比率を計算する
   m_handle_ma_fast_h1 = iMA(_Symbol, PERIOD_H1, InpH1_MA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   m_handle_ma_slow_h1 = iMA(_Symbol, PERIOD_H1, InpH1_MA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   //--- iADX はシンボル・時間足・期間の 3 つを指定すれば十分なため、余計な価格種別パラメータを削除
   //     これによりコンパイル時の引数数エラーを解消し、ADX 判定に必要なハンドルだけを正しく生成する
   m_handle_adx_h1     = iADX(_Symbol, PERIOD_H1, InpH1_ADX_Period);
   m_handle_atr_h1     = iATR(_Symbol, PERIOD_H1, 14);

   if(m_handle_ma_fast_h1==INVALID_HANDLE ||
      m_handle_ma_slow_h1==INVALID_HANDLE ||
      m_handle_adx_h1    ==INVALID_HANDLE ||
      m_handle_atr_h1    ==INVALID_HANDLE)
     {
      // いずれかのハンドル生成に失敗した場合はエラーログを出しておく
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
   // H1 の新しいバーが確定したタイミングでレジーム判定を行う
   // ここでは「確定バー（shift=1）」の値を使用して、過去データだけで判定する。

   // インジケータハンドルが未初期化の場合は、安全のためレジーム更新を行わない
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
   double atr     = atr_val[0];              // 正規化用の ATR（H1）
   double adx     = adx_val[0];              // トレンドの強さ

   if(atr <= 0.0)
     {
      // ATR が 0 付近だと比率計算が不安定になるため、その場合は更新を見送る
      LogPrint("WARN", "REGIME", "OnNewBarH1: ATR_H1 が 0 もしくは負のためレジーム更新をスキップします。");
      return;
     }

   double ma_diff_atr_ratio = MathAbs(ma_diff) / atr;

   int    new_regime    = m_regime;
   double new_trend_dir = 0.0;

   //--- トレンド判定
   if(adx >= InpTrend_ADX_Min && ma_diff_atr_ratio >= InpTrend_MA_ATR_DiffMin)
     {
      new_regime    = REGIME_TREND;
      new_trend_dir = (ma_diff > 0.0 ? 1.0 : -1.0); // MA_fast > MA_slow なら上昇トレンド、逆なら下降トレンド
     }
   //--- レンジ判定
   else if(adx <= InpRange_ADX_Max && ma_diff_atr_ratio <= InpRange_MA_ATR_DiffMax)
     {
      new_regime    = REGIME_RANGE;
      new_trend_dir = 0.0; // レンジ中は方向性 0 として扱う
     }
   //--- それ以外はカオス（急変動や移行期など）
   else
     {
      new_regime    = REGIME_CHAOS;
      new_trend_dir = 0.0;
     }

   // レジームまたはトレンド方向に変化があった場合のみ内部状態を更新
   if(new_regime != m_regime || new_trend_dir != m_trend_dir)
     {
      m_regime           = new_regime;
      m_trend_dir        = new_trend_dir;
      m_last_change_time = TimeCurrent();

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
   // レジーム変更直後にエントリを控えるためのクールダウン判定
   // 「最後にレジームが変化した H1 バー」から何本経過したかで判断する。
   if(m_last_change_time==0)
      return(false);

   // クールダウンバー数が 0 以下ならクールダウン機能自体を無効化
   if(InpRegimeCooldownBars_H1 <= 0)
      return(false);

   // iBarShift を使って、現在の H1 バーとレジーム変更時のバーのインデックス差を求める
   int shift_change = iBarShift(_Symbol, PERIOD_H1, m_last_change_time, true);
   int shift_now    = iBarShift(_Symbol, PERIOD_H1, TimeCurrent(),      true);

   if(shift_change < 0 || shift_now < 0)
      return(false);

   int bars_diff = shift_change - shift_now; // 値が小さいほど最近のバー

   // 直近 InpRegimeCooldownBars_H1 本の間はクールダウン中とみなす
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
   void              Attach(CRegimeEngine *reg, CStateTracker *state);
   bool              CanOpen(); // 新規エントリ可能か？
  };

CGlobalGate::CGlobalGate()
  {
   m_regime_engine = NULL;
   m_state_tracker = NULL;
  }

void CGlobalGate::Attach(CRegimeEngine *reg, CStateTracker *state)
  {
   m_regime_engine = reg;
   m_state_tracker = state;
  }

bool CGlobalGate::CanOpen()
  {
   //================================================================
   // 1) モジュールのアタッチ状態チェック
   //================================================================
   if(m_regime_engine == NULL || m_state_tracker == NULL)
     {
      // 何かがおかしい状態なので、安全側に倒してエントリを禁止する
      LogPrint("ERROR", "GATE", "CanOpen: RegimeEngine または StateTracker が未アタッチです。");
      return(false);
     }

   //================================================================
   // 2) 取引時間帯フィルタ
   //    - InpTradeStartHour ～ InpTradeEndHour の間だけ新規エントリを許可
   //    - 終了時刻が開始時刻より小さい場合は「日またぎ」とみなす（例: 16～3 時）
   //================================================================
   MqlDateTime mt;
   TimeToStruct(TimeCurrent(), mt);
   int hour = mt.hour;

   bool time_ok = false;
   if(InpTradeStartHour == InpTradeEndHour)
     {
      // 同じ値の場合は「24 時間許可」として扱う
      time_ok = true;
     }
   else if(InpTradeStartHour < InpTradeEndHour)
     {
      // 同一日内で完結する時間帯
      time_ok = (hour >= InpTradeStartHour && hour < InpTradeEndHour);
     }
   else
     {
      // 日またぎ時間帯（例: 16～3 時）
      time_ok = (hour >= InpTradeStartHour || hour < InpTradeEndHour);
     }

   if(!time_ok)
      return(false);

   //================================================================
   // 3) 日次 / 週次ドローダウンチェック
   //    CStateTracker は JPY 建て損益を保持しているため、口座残高に対する %
   //    へ変換してから閾値と比較する。
   //================================================================
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > 0.0)
     {
      //--- ドローダウン値を安全に読み出す
      //     変数配置をシンプルにし、NULL チェックの後に順番に値を取得する。
      double daily_dd_value  = 0.0;
      double weekly_dd_value = 0.0;

      // ポインタが無効なら即座に終了し、ログで異常を通知
      CStateTracker *state_ptr = m_state_tracker;
      if(state_ptr == NULL)
        {
         LogPrint("ERROR", "GATE", "CanOpen: StateTracker が NULL です (DD 取得失敗)。");
         return(false);
        }

      //--- ポインタ経由で値を順に取得（MQL はポインタでもドット演算子を使う点に注意）
      //     C/C++ 風に "->" を用いると "'>' - operand expected" となるため、
      //     安全にドット演算子でメソッドを呼び出す。
      daily_dd_value  = state_ptr.DailyDD();
      weekly_dd_value = state_ptr.WeeklyDD();

      //--- 口座残高に対するパーセンテージへ変換
      double daily_dd_pct  = 100.0 * MathAbs(daily_dd_value)  / balance;
      double weekly_dd_pct = 100.0 * MathAbs(weekly_dd_value) / balance;

      //--- 最大許容 DD を超えた場合は、その日 / 週の新規エントリを停止
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
   //    - 絶対スプレッド(pips) が InpMaxSpreadPips を超える場合はエントリ禁止
   //    - ATR_M1 が取得できる場合は Spread(pips) / ATR_M1(pips) の比率もチェック
   //================================================================
   long spread_points = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SPREAD, spread_points))
     {
      // スプレッド情報が取得できないのは異常なのでエントリ禁止
      LogPrint("ERROR", "GATE", "CanOpen: SYMBOL_SPREAD が取得できません。");
      return(false);
     }

   double point    = _Point;
   double pip_size = (_Digits == 3 || _Digits == 5) ? 10.0 * point : point; // USDJPY 等: 0.01 が 1 pip
   double spread_pips = (double)spread_points * point / pip_size;

   if(spread_pips <= 0.0)
     {
      LogPrint("WARN", "GATE", "CanOpen: スプレッドが 0 以下のためエントリをスキップします。");
      return(false);
     }

   // 絶対スプレッドの上限チェック
   if(spread_pips > InpMaxSpreadPips)
     {
      LogPrint("INFO", "GATE",
               StringFormat("CanOpen: スプレッドが上限を超過 (Spread=%.2f pips, Max=%.2f pips)",
                            spread_pips, InpMaxSpreadPips));
      return(false);
     }

   // ATR_M1 を使った相対スプレッド比チェック
   if(InpMaxSpreadATRRatio > 0.0 && g_handle_atr_m1 != INVALID_HANDLE)
     {
      double atr_buf[1];
      if(CopyBuffer(g_handle_atr_m1, 0, 1, 1, atr_buf) == 1)
        {
         double atr_m1      = atr_buf[0];                           // 価格単位
         double atr_m1_pips = (atr_m1 > 0.0 ? atr_m1 / pip_size : 0.0); // pips に換算

         if(atr_m1_pips > 0.0)
           {
            double ratio = spread_pips / atr_m1_pips;

            if(ratio > InpMaxSpreadATRRatio)
              {
               LogPrint("INFO", "GATE",
                        StringFormat("CanOpen: Spread/ATR 比が上限を超過 (Spread=%.2f pips, ATR_M1=%.2f pips, Ratio=%.2f, Max=%.2f)",
                                     spread_pips, atr_m1_pips, ratio, InpMaxSpreadATRRatio));
               return(false);
              }
           }
        }
     }

   //================================================================
   // 5) レジーム変更直後のクールダウン
   //================================================================
   //--- レジームエンジンのポインタを再確認した上でクールダウン状態を取得する。
   //     三項演算子や論理積でまとめると、稀にコンパイル時に解釈が
   //     不安定になるケースがあるため、明示的な if 構造で安全に値を取得する。
   bool           in_cooldown = false;
   CRegimeEngine *reg_ptr     = m_regime_engine; // ローカルに保持してから参照

   //--- ポインタが無効ならすぐに終了し、安全側に倒す
   if(reg_ptr == NULL)
     {
      LogPrint("ERROR", "GATE", "CanOpen: RegimeEngine が NULL です (クールダウン判定不可)。");
      return(false);
     }

   // 参照型束縛はローカルでは使えないため、NULL チェック後にドット演算子で
   // 状態を取得する。ポインタであっても "->" ではなくドットを使う点を明記。
   // これにより前回報告された演算子誤解釈エラーを解消する。
   in_cooldown = reg_ptr.InCooldown();

   if(in_cooldown)
     {
      // クールダウン中は新規ポジションを控える
      return(false);
     }

   //================================================================
   // 6) ニュースフィルタ
   //    Phase1 ではまだ具体的なニュース連携は行わないため、フラグが ON の場合でも
   //    ログを出すだけに留める。将来的に外部 CSV / Web 連携を実装する想定。
   //================================================================
   if(InpUseNewsFilter)
     {
      // TODO: ニュース時間帯の取得ロジックを実装する
      // 現時点では挙動を変えたくないため、判定には使わずログのみ。
      //LogPrint("INFO", "GATE", "CanOpen: ニュースフィルタは未実装（ログのみ）。");
     }

   // ここまで全ての条件をパスした場合にのみ新規エントリを許可
   return(true);
  }


//==================================================================
// 各アルファクラスの骨格定義
//==================================================================

//--------------------------------------------------------------
// CAlphaA : 圧縮ブレイク順張り
//--------------------------------------------------------------
class CAlphaA
  {
private:
   int      m_magic;
public:
                     CAlphaA(int magic_base);
   void              Init();
   void              OnNewBarM5();                 // M5新バー時に状態更新
   bool              GetSignal(TradeSignal &sig);  // シグナル生成
  };

CAlphaA::CAlphaA(int magic_base)
  {
   m_magic = magic_base + 1; // AlphaA用のマジック番号
  }

void CAlphaA::Init()
  {
   // TODO: 必要なバッファ初期化など
   LogPrint("INFO", "ALPHA_A", "Init called");
  }

void CAlphaA::OnNewBarM5()
  {
   // TODO: 圧縮状態の検出ロジックをここに実装
  }

bool CAlphaA::GetSignal(TradeSignal &sig)
  {
   // TODO: 条件を満たした場合に sig を埋めて true を返す
   sig.is_valid = false;
   return(false);
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

//--- リスク[%]とSL幅[pips]からロットを計算（簡易版・骨格）
double CRiskManager::CalcLotByRisk(double sl_pips)
  {
   if(sl_pips <= 0.0)
      return(0.0);

   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt = balance * InpRiskPerTrade / 100.0;

   // pips -> 損失通貨額への換算はブローカー仕様によって異なる
   // Phase1骨格では簡易に「1pipsあたり一定金額」と仮定して雑に割る
   // TODO: 実装時に TickValue などを用いて正確に計算する
   double pip_value = 10.0; // ダミー値
   double lots      = risk_amt / (sl_pips * pip_value);
   if(lots < 0.0)
      lots = 0.0;

   return(lots);
  }

//--- 各Alphaのシグナルを受け取り、どれを実行するか決めて注文発行（骨格）
bool CRiskManager::Execute(TradeSignal &sig_a,
                           TradeSignal &sig_b,
                           TradeSignal &sig_c)
  {
   // TODO:
   // 1) レジームと整合するシグナルを優先
   // 2) 期待RやTP距離 / Spread 比などで優先度を決める
   // 3) 選ばれたシグナルに対して Lot を計算し、CTradeで注文
   // Phase1では何もしない
   return(false);
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

   //--- M1 ATR インジケータハンドルを生成（スプレッド/ATR 比フィルタ用）
   //     ここでは period=14 の ATR を使用し、確定バーのボラティリティとして参照する。
   g_handle_atr_m1 = iATR(_Symbol, PERIOD_M1, 14);
   if(g_handle_atr_m1 == INVALID_HANDLE)
     {
      LogPrint("ERROR", "INIT", "M1 ATR ハンドルの作成に失敗しました。スプレッド/ATR フィルタは無効になります。");
     }
   else
     {
      LogPrint("INFO", "INIT", "M1 ATR ハンドル作成完了。");
     }

   //--- 各モジュール初期化
   g_regime.Init();
   g_state.Init();
   g_gate.Attach(&g_regime, &g_state);

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
