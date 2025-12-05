//+------------------------------------------------------------------+
//|                                  UnifiedTrendRevertEA_Integrated.mq5
//|  概要：H1の回帰β×σ（48本）でTRD/RNGを自動判定（ヒステリシス）。
//|        ・TRD：M5ブレイクアウト（HH/LL=6本, Edge≥0.85, 逆指値, EntryBuffer=0.28×ATR(M5)）
//|        ・RNG：M1平均回帰（PF-extreme準拠：|z|≥1.60, VR≤1.05, OU∈[6,90], 時間帯, 指値）
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

//============================= サーバー時刻共通取得 ============================
// 目的   : MQL5ドキュメント（https://www.mql5.com/ja/docs/dateandtime/timecurrent）
//          では TimeCurrent が「サーバー時刻を返す」標準APIとして案内されている。
//          しかしビルド環境によっては TimeTradeServer / TimeCurrent のどちらかが
//          未定義になるケースが報告されたため、関数化＋条件コンパイルで安全に
//          フォールバックさせる。マクロではなく関数に戻すことで「引数が多い」
//          といったマクロ解釈ミスを根本的に排除する。
// 優先順 : 1) MQL5なら TimeTradeServer() を最優先（サーバー基準が最も正確）
//          2) 上記が使えない場合は TimeCurrent()（MQL4/5共通で広く使える）
//          3) どちらも使えない特殊環境では TimeLocal() を最後の砦として使用
// 戻り値 : datetime（利用可能な最上位APIで取得した時刻）
// 注意   : 常にサーバー基準の計算を試み、未定義エラーを避けるため #ifdef で
//          呼び出し可能なAPIだけをコンパイルに含める。コメントも合わせて残す。
//---------------------------------------------------------------------------
datetime GetServerTime()
{
   // MQL5ならドキュメント推奨の TimeTradeServer を最初に試す。未定義環境では
   // このブロック自体がコンパイルされないため、呼び出しでの「未定義識別子」
   // エラーを完全に防げる。
#ifdef __MQL5__
   return TimeTradeServer();
#else
   // MQL4互換やTimeTradeServerが存在しない環境では TimeCurrent を使う。
   // これも未定義な極端な環境では次のフォールバックに進む。
   return TimeCurrent();
#endif

   // ここに到達するのは TimeCurrent すら提供されない想定外の環境のみ。
   // ゼロ時刻を返すよりは端末ローカル時刻を返した方がログの解析に有用。
   // （MQLプリプロセッサは #else の後にコードがあっても、上で return すれば
   //   最適化で消されるためパフォーマンス上の問題は極小）
   return TimeLocal();
}

//=========================== 入 力 値 ===============================
// ■ゲート（H1 回帰β×σ）／ヒステリシス
input bool   InpUseHysteresis     = true;     // ヒステリシスを使う
input int    InpBetaWindow        = 48;       // β算出窓（H1本数）
input double InpEnterCoef         = 0.0022;   // TRD入り： |β| ≥ σ×EnterCoef
input double InpExitCoef          = 0.0018;   // RNG戻り： |β| ≤ σ×ExitCoef
input double InpNoHysCoef         = 0.0020;   // ヒステリシスOFF時の単一しきい値

// ■モジュール全体のON/OFFを一括で切り替える入力（TRD/RNGを一つの設定で管理）
enum InpModuleMode
{
   MODE_BOTH     = 0, // TRDとRNGの両方を稼働
   MODE_TRD_ONLY = 1, // TRDのみ稼働（RNGは停止）
   MODE_RNG_ONLY = 2, // RNGのみ稼働（TRDは停止）
   MODE_ALL_OFF  = 3  // すべて停止（監視のみ）
};
input InpModuleMode InpModuleSwitch = MODE_BOTH; // 運用モード切替（ここ1つで両モジュールを一括管理）

// ■TRD（ブレイクアウト）
input double InpEntryBufferATR    = 0.28;     // 逆指値バッファ（ATR(M5)×倍率）※0.25-0.30で精度重視、ダマシ除去目的で距離を広げる
input double InpEdgeEntryMin      = 0.85;     // Edgeエントリ下限（0..1）※強トレンドのみ狙うため0.85で精度優先に設定
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
input double InpZ_in                 = 2.00;     // |z|閾値（クロス／滞留トリガー共通）※2.0推奨（2.4→2.0で頻度↑）
input int    InpZHoldBars            = 3;        // |z|が閾値以上に張り付いた場合の滞留本数トリガー
input double InpZ_cut                = 3.0;      // |z| ≥ Z_cut で損切り
input double InpVR_Thr               = 1.15;     // VR ≤ 1.15（ボラ許容を緩めて参入機会を増やす）
input int    InpOU_Min               = 4;        // OU 時間の下限（超短期の均衡も許容してトリガーを拡大）
input int    InpOU_Max               = 150;      // OU 時間の上限（長時間の停滞も許容してヒットを増やす）
input bool   InpRngUseBBW            = true;     // BB幅判定を使うか（true推奨）
input double InpBBW2ATR              = 1.10;     // BB幅/ATRの許容上限（0.8→1.1で“やや広いレンジ”でも許容）
input double InpOffset_ATR           = 0.10;     // 指値オフセット = min(0.10×ATR(M1), 0.4×spread) として価格に寄せる
input double InpOffset_Spread        = 0.4;      // 同上のスプレッド係数（安全側を確保しつつ控えめに寄せる）
input int    InpRngExpiryBars        = 18;       // 指値の有効期限（M1本数）。短めに掃除して再発注機会を回す
input int    InpRngReanchorCooldown  = 12;       // 再アンカーを許可する最短間隔（M1本数）。毎分置き直しを防止
input double InpRngReanchorShiftATR  = 0.30;     // 前回アンカー基準からこれだけ乖離したら再アンカー許可（×ATR）
input int    InpRngLadderCount       = 2;        // ラダー段数（1〜2）。2段まで許可して約定機会を増やす
input double InpRngLadderStepATR     = 0.35;     // 段間隔（×ATR）。約0.35ATRずつ価格をずらして待つ
input int    InpRngLadderPct1        = 50;       // 第1段のロット割合[%]。残りは2段目に割り当てる
input int    InpAllowedStartJST      = 17;       // 取引時間（JST）の開始（例17）
input int    InpAllowedEndJST        = 24;       // 取引時間（JST）の終了（例24→0時まで）
input int    InpMaxHold_Min          = 60;       // 最大保有分数（RNG）
input bool   InpRNG_UseSL            = false;    // RNGに任意SLを設定（既定OFF）
input double InpRNG_SL_ATR_H1        = 2.0;      // RNG SL距離（×ATR(H1)）
input bool   InpRngDebugLog          = false;    // RNGの判定経路を詳細ログ出力して原因調査を容易化（デフォルトOFF）

// ■ブローカー時差
//   TimeGMTOffset() で自動検出を試み、ズレがある場合は InpBrokerUTCOffsetHours を手動指定する。
//   例: サーバーがUTC+2 → +2、UTC-3 → -3。これを使って UTC→JST(+9)補正を行う。
input bool   InpAutoDetectBrokerOffset = true; // サーバーのUTCオフセットを自動検出して使うか（検出失敗時は手動値にフォールバック）
input int    InpBrokerUTCOffsetHours   = 0;    // 自動が不正確な場合の上書き用。0は「そのまま」を意味しないことに注意

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

// RNGの発火判定用の状態（クロス検出と滞留カウントを保持）
double   lastZ_forTrigger = 0.0; // 直近M1バーのz値を保持し、閾値クロスを検出する
int      zHoldCount       = 0;   // |z|が閾値以上に滞留した本数をカウント

// RNGの再アンカー制御用。最後にアンカーした基準価格とバー時刻を方向別に保持
double   lastAnchorPriceBuy  = 0.0;
double   lastAnchorPriceSell = 0.0;
datetime lastAnchorTimeBuy   = 0;
datetime lastAnchorTimeSell  = 0;

// バー更新記録
datetime lastM5BarTime = 0;
datetime lastM1BarTime = 0;

// レジーム
enum Regime { REG_RNG = 0, REG_TRD = 1 };
Regime lastRegime = REG_RNG;        // ← ヒステリシス参照もこの値に統一

// H1確定バー切替を記録し、レジーム変化バーでは新規エントリを禁止するためのフラグ
datetime lastH1BarTime = 0;         // 直近H1バーの時刻
bool     inhibitEntryThisH1Bar=false; // レジーム変化が発生したH1バー内ではtrue

//=========================== 関 数 宣 言 =============================
bool   CacheSeries();

Regime CalcRegimeH1();                       // H1ゲート（β×σ、ヒステリシス）
double EdgeScore(int sh);                    // M5 Edge（0..1）
bool   GetHHLL(int sh, double &hh, double &ll);

bool   FindLastPivotLowBelow(double entryPrice, double &pivotLow);
bool   FindLastPivotHighAbove(double entryPrice, double &pivotHigh);
double CalcInitialSL(bool isBuy, double entry);

double EdgeLong(int sh);                     // Edgeの方向別（ロング側強度）
double EdgeShort(int sh);                    // Edgeの方向別（ショート側強度）
void   ManagePositionExit_TRD();             // TRD EXIT（STRUCT/BURST/EDGE）
void   TryPlaceBreakoutStops();              // TRD 逆指値

void   ManagePositionExit_RNG(Regime cur);   // RNG EXIT（z/時間/TRD化）
void   TryPlaceMeanRevertLimits(Regime cur); // RNG 指値

bool   AnyOpenPosition();
void   CancelAllPendings();
void   CancelAllPendingsByTag(const string tag);
bool   HasPendingByTag(const string tag);           // 指定タグの保留注文が存在するか確認
int    CountPendingByTagPrefix(const string prefix); // 指定プレフィックスの保留件数を取得
int    CountPendingBySubstring(const string needle); // コメントに部分一致する保留件数

void   SelfReviewStatus(Regime regime, bool trdEnabled, bool rngEnabled, bool bothEnabled); // モード・レジーム状況のセルフチェック

bool   ComputeZ_VR_OU(int sh, double &z, double &vr, double &ou_time);

int    CurrentHourJST();                     // ブローカー時刻→UTC→JST(+9)
bool   IsTRDEnabled();                       // 運用モードから求めるTRD可否
bool   IsRNGEnabled();                       // 運用モードから求めるRNG可否

//============================= 有効判定 ==============================
// モード切替のみで最終的にTRD/RNGを稼働させるかを返す。
// 以前は個別スイッチ（InpEnableTRD/RNG）と併用していたが、
// InpModuleSwitch の導入で役割が重複したため、モード1本に統一する。
bool IsTRDEnabled()
{
   // 運用モードのみでTRD可否を判断（スイッチ削減で設定ミスを防ぐ）
   switch(InpModuleSwitch)
   {
      case MODE_BOTH:     return true;  // 両方稼働
      case MODE_TRD_ONLY: return true;  // TRDのみ稼働
      case MODE_RNG_ONLY: return false; // RNG専用モードではTRD停止
      case MODE_ALL_OFF:  return false; // 完全停止
      default:            return false; // 想定外値は安全側で停止
   }
}

bool IsRNGEnabled()
{
   // 運用モードのみでRNG可否を判断（単一入力で混乱を避ける）
   switch(InpModuleSwitch)
   {
      case MODE_BOTH:     return true;  // 両方稼働
      case MODE_TRD_ONLY: return false; // TRD専用モードではRNG停止
      case MODE_RNG_ONLY: return true;  // RNGのみ稼働
      case MODE_ALL_OFF:  return false; // 完全停止
      default:            return false; // 想定外値は安全側で停止
   }
}

//============================= 初 期 化 ==============================
int OnInit()
{
   sym = _Symbol;

   //--- H1バーの初期時刻を保持（レジーム変化バー検出に使用）
   lastH1BarTime = iTime(sym, TF_H1, 0);

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

   // モードと個別入力を合成した有効/無効判定を先に取得しておく
   bool trdEnabled = IsTRDEnabled();
   bool rngEnabled = IsRNGEnabled();

   // H1のバー更新を検出（レジーム変化バー判定に使用）
   datetime curH1 = iTime(sym, TF_H1, 0);
   bool newH1Bar  = (curH1 != lastH1BarTime);
   if(newH1Bar)
      lastH1BarTime = curH1;

   // H1ゲート（確定バーでβ×σ計算、ヒステリシスは lastRegime 参照）
   // ただしモジュールが片側しか有効でない場合はゲート計算をスキップして強制レジームへ固定する。
   // さらに「強制レジーム固定」でヒステリシス抑止がかかり続けないよう、ゲート不使用時は
   // 新規抑止フラグを解除して即座に発注できるようにする。
   Regime regimeRaw;
   bool bothEnabled = (trdEnabled && rngEnabled); // 両方稼働時のみゲートを計算
   if(bothEnabled)
   {
      // 本来のβ×σゲートを計算（ヒステリシス付き）
      regimeRaw = CalcRegimeH1();
   }
   else if(trdEnabled && !rngEnabled)
   {
      // TRD専用運用では常にTRD扱い。ゲートを見ないことで「RNGレジームで足止め」される事態を防ぐ。
      regimeRaw = REG_TRD;
   }
   else if(!trdEnabled && rngEnabled)
   {
      // RNG専用運用では常にRNG扱い。TRDレジームに切り替わる要素を排除し、発注停止を防ぐ。
      regimeRaw = REG_RNG;
   }
   else
   {
      // 全停止（MODE_ALL_OFFなど）では安全側でRNG固定。以降の判定は有効フラグで弾かれる。
      regimeRaw = REG_RNG;
   }

   // TRD/RNGの有効フラグに応じて“運用上のレジーム”を上書きする
   // ・TRD無効かつRNG有効: ゲートがTRDを示してもRNGを動かす（TRD停止時に0件になる問題を防止）
   // ・RNG無効かつTRD有効: ゲートがRNGを示してもTRDを動かす（将来の片側無効化にも備える）
   // ・両方有効/無効: ゲート結果をそのまま使用（無効時はそもそも発注しない）
   // 一括モード(InpModuleSwitch)で上記の有効判定を作っている点に注意。
   Regime regime = regimeRaw;
   if(!trdEnabled && rngEnabled) regime = REG_RNG;
   if(!rngEnabled && trdEnabled) regime = REG_TRD;

   // ゲート計算を行った場合のみヒステリシス遷移と抑止を適用する。
   // 片側固定モードでは「ゲート非使用＝遷移なし」とみなして抑止を解除し、
   // 強制モードでも即時発注できるようにする。
   if(bothEnabled)
   {
      // 生のゲート判定が変化した場合のみヒステリシス状態を更新し、遷移バー抑制をかける
      // （上書き後のregimeは実際の発注判定に使用する）
      if(regimeRaw != lastRegime)
      {
         PrintFormat("H1 Regime 変更: %s -> %s",
                     lastRegime==REG_TRD?"TRD":"RNG",
                     regimeRaw==REG_TRD?"TRD":"RNG");
         // 状態遷移バーでは新規発注を抑制。安全のため保留注文は一旦全キャンセル。
         CancelAllPendings();
         lastRegime = regimeRaw;
         inhibitEntryThisH1Bar = true;   // このH1バー内の新規エントリを抑制
      }
      else if(newH1Bar)
      {
         // レジーム変化が無ければ、次のバーから新規エントリを許可する
         inhibitEntryThisH1Bar = false;
      }
   }
   else
   {
      // ゲート非使用モードではヒステリシス遷移による抑止を発生させず、
      // lastRegime を強制レジームに同期させて「永遠に遷移中」が起きないようにする。
      lastRegime = regimeRaw;
      inhibitEntryThisH1Bar = false; // 強制モードではバー跨ぎを待たずに発注を許可
   }

   // H1バー単位でセルフレビュー用の状態ダンプを出力し、
   // 「モードとレジームが一致しているのに撃たない」などの調査を容易にする。
   if(newH1Bar)
      SelfReviewStatus(regime, trdEnabled, rngEnabled, bothEnabled);

   // ==== M5 新バー（TRDモジュール）====
   datetime curM5 = iTime(sym, TF_M5, 0);
   if(curM5 != lastM5BarTime)
   {
      lastM5BarTime = curM5;

      // 既存TRDポジのEXIT（STRUCT/BURST/EDGE）※確定M5で判定
      ManagePositionExit_TRD();

      // TRD：新規逆指値（1ポジ制御・確定値判定）
      if(trdEnabled && regime==REG_TRD && !AnyOpenPosition() && !inhibitEntryThisH1Bar)
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
      if(rngEnabled && regime==REG_RNG && !AnyOpenPosition() && !inhibitEntryThisH1Bar)
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
// 回帰傾きβと残差標準偏差σを求め、ヒステリシス（lastRegime）でTRD/RNGを安定切替。
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

   // 回帰直線の切片と残差を用いた標準偏差を求める（β×σのσを厳密化）
   double intercept = yMean - beta*xMean;
   double residualSqSum = 0.0;
   for(int r=0; r<N; ++r)
   {
      double xi = r;
      double y  = H1_close[start - r];
      double fit = intercept + beta*xi;
      double resid = y - fit;
      residualSqSum += resid*resid;
   }
   // 標本分散としてN-1で割り、安定化のためゼロ除算はガード
   double sigma = (N>1 ? MathSqrt(residualSqSum/(N-1)) : 0.0);

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

//-------------------------------------------------------------------------
// EdgeLong / EdgeShort
// EdgeScore は「上方向が強いほど大きい（0..1）」指標のため、ショート側は
// 対称性を保つよう (1 - EdgeScore) で弱さ→強さを測る。入口・出口ともに
// 同一しきい値を使うことでロング/ショートの公平性を担保する。
//-------------------------------------------------------------------------
double EdgeLong(int sh)
{
   // ロング優位度をそのまま返す（0..1）
   return EdgeScore(sh);
}

double EdgeShort(int sh)
{
   // ショート優位度は EdgeScore の鏡像で表現（0..1）。0.5 を境に対称。
   return 1.0 - EdgeScore(sh);
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
      // 建玉方向ごとに「自方向エッジのみ」を監視し、連続で弱い場合に決済。
      // MathMax で片側の強さに引っ張られないよう、左右対称の判定にする。
      bool under=true;
      for(int k=0;k<InpEDGE_Consec;k++)
      {
         double e = (type==POSITION_TYPE_BUY) ? EdgeLong(sh+k) : EdgeShort(sh+k);
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
   // ロング/ショートで同一しきい値を用いるが、方向専用のエッジを使うことで
   // 判定を完全に左右対称にする。
   double edgeL = EdgeLong(sh);
   double edgeS = EdgeShort(sh);
   // 直近2本連続で方向エッジがしきい値以上かを確認し、
   // 「瞬間的な尖り」を排除して強いトレンドのみを通す
   bool allowLong  = (edgeL >= InpEdgeEntryMin && EdgeLong(sh+1)  >= InpEdgeEntryMin);
   bool allowShort = (edgeS >= InpEdgeEntryMin && EdgeShort(sh+1) >= InpEdgeEntryMin);

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

   // BUY STOP：close>HH かつ ロング側エッジがしきい値以上 → BuyStop=HH+buf
   if(c > hh && allowLong)
   {
      double price = NormalizeDouble(hh + buf, digits);
      // 最小距離（stop/freeze）を確保
      if(minPts>0 && (price - tk.ask) < minPts*pt) price = tk.ask + minPts*pt;

      double sl = CalcInitialSL(true, price);
      bool ok = Trade.BuyStop(InpLots, price, sym, sl, 0.0, ORDER_TIME_GTC, 0, "TRD_BUYSTOP");
      if(!ok) Print("BuyStop失敗:", _LastError);
   }
   // SELL STOP：close<ll かつ ショート側エッジがしきい値以上 → SellStop=LL-buf
   else if(c < ll && allowShort)
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
   // サーバー現在時刻はGetServerTime()から取得し、TimeCurrent/TimeTradeServerが片方未定義でも
   // ビルドできるようにする（できる限りサーバー基準で経過時間を測る）。
   int heldMin = (int)MathFloor((GetServerTime() - etime)/60.0);
   if(heldMin >= InpMaxHold_Min) doExit=true;

   if(doExit)
   {
      bool ok=Trade.PositionClose(sym, InpSlippage);
      if(!ok) Print("RNG EXIT失敗:", _LastError);
   }
}

//============================= RNG 指値 =============================
// 時間帯（JST）・VR・OUを満たしたうえで、|z|閾値のクロス／滞留トリガーを検出して
// BuyLimit / SellLimit を設置する。ラダー（最大2段）、期限付き再アンカー、
// BB幅判定を追加し、「撃たなすぎ」を解消しながら無駄打ちを抑制する。
// 任意SL（InpRNG_UseSL=true）時は H1 ATR に対する±距離でSL設定。
//====================================================================
// RNGのスキップ理由を詳細に残す専用ロガー。
// MQL5 はラムダ式をサポートしないため、局所関数化ではなく専用の
// ヘルパー関数に切り出して再利用する。ログ量はデバッグ時のみ有効。
// hourJST を渡すのは時間帯不一致の原因を切り分けるため（-1は不明を示す）。
// isSkip=false の場合は「情報」を示すインフォログとして扱い、スキップ扱いではないことを明確にする。
// vrThr/bbwThr は「どのしきい値で落ちたか」を明示して誤設定を早期に検知するために追加している。
void LogRngSkip(const string reason, double zVal, double vrVal, double ouVal, Regime cur, int hourJST=-1, double ouMin=-1.0, double ouMax=-1.0, bool isSkip=true, double vrThr=-1.0, double bbwThr=-1.0)
{
   if(!InpRngDebugLog) return; // デバッグ無効ならログも抑止

   // 時刻・z/VR/OU・レジーム・保有状況をまとめて可視化することで、
   // 「どこで条件が落ちたか」を後から追跡しやすくする。
   string prefix = isSkip?"RNGDBG skip:" : "RNGDBG info:";
   // VR/BBWのしきい値を明示し、入力値の誤りや意図しない最適化設定をすぐに発見できるようにする。
   PrintFormat("%s %s hourJST=%d mode=%d regime=%s pos=%s pend(B/S)=%d/%d z=%.3f VR=%.3f(Thr=%.3f) OU=%.1f OUwin=[%.1f..%.1f] BBWThr=%.3f",
               prefix,
               reason,
               hourJST,
               (int)InpModuleSwitch,
               (cur==REG_TRD?"TRD":"RNG"),
               AnyOpenPosition()?"YES":"NO",
               CountPendingByTagPrefix("RNG_BUYLIMIT"),
               CountPendingByTagPrefix("RNG_SELLLIMIT"),
               zVal,
               vrVal,
               vrThr,
               ouVal,
               ouMin,
               ouMax,
               bbwThr);
}

//====================================================================
void TryPlaceMeanRevertLimits(Regime cur)
{
   // OUレンジはログ表示と判定双方で使うため、最初に確定させて値を保持する
   // （RNG専用モードの時間帯バイパス時にも [-1..-1] とならないよう明示的に渡す）。
   double ouMin = MathMin((double)InpOU_Min, (double)InpOU_Max); // 入力の大小が逆でも下限に収束
   double ouMax = MathMax((double)InpOU_Min, (double)InpOU_Max); // 同上（上限）
   double ouTol = 1e-6; // 微小な浮動小数誤差で閾値を跨いだと見なされるのを防止

   // 時間帯（JST）判定
   int hourJST = CurrentHourJST();
   bool inHours=false;

   // RNG専用モードでは「夜間のみ」という制限で発注ゼロになるのを防ぐため、
   // 時間帯フィルタ自体をスキップする。TRD併用時だけ従来の窓を適用する。
   bool enforceHours = (InpModuleSwitch != MODE_RNG_ONLY);
   bool hoursBypassed = false; // trueなら後段でインフォログを1回だけ残す
   if(enforceHours)
   {
      // 通常の時間帯判定ロジック（従来挙動）
      if(InpAllowedStartJST <= InpAllowedEndJST)
      {
         // 一般的な範囲指定（例:17→24）。終端が24の場合、JST 0時も許容する。
         inHours = (hourJST >= InpAllowedStartJST && hourJST <= InpAllowedEndJST);
         if(InpAllowedEndJST==24 && hourJST==0) inHours=true; // 仕様の{17..23,0}を忠実に再現
      }
      else
      {
         // 開始>終了のラップ指定（例:22→6 等）
         inHours = (hourJST >= InpAllowedStartJST || hourJST <= InpAllowedEndJST);
      }

      if(!inHours)
      {
         // 時間帯不一致の場合は計算済みhourJSTを残し、ずれの原因を追いやすくする
         // 時間帯不一致であっても、VR/BBWのしきい値を併記することで設定値との不整合を後から検知できるようにする
         LogRngSkip("hour_out_of_range", lastZ_forTrigger, 0.0, 0.0, cur, hourJST, ouMin, ouMax, true, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
         return;
      }
   }
   else
   {
      // RNG専用モードは24時間許容。スキップではなく「バイパスした」事実をログに残し
      // つつ、OUレンジを明示して [-1..-1] にならないよう可視化する。メトリクスを計測
      // した後にインフォログとして1回だけ出力することで、ゼロ値による誤解を避ける。
      inHours=true;
      hoursBypassed=true;
   }

   // 指標（確定M1）
   int sh=1;
   double z, vr, ou;
   if(!ComputeZ_VR_OU(sh, z, vr, ou))
   {
      // 計算失敗時も入力しきい値を残し、データ欠損と設定値のどちらが原因かを切り分けやすくする
      LogRngSkip("ComputeZ_VR_OU_failed", lastZ_forTrigger, 0.0, 0.0, cur, hourJST, ouMin, ouMax, true, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
      return;
   }

   // 時間帯をバイパスした場合は、実計測値付きのインフォログをここで一度だけ出す。
   // 「skip」ではなく「info」として明示し、RNG専用モードでは時間帯チェックが無効
   // であることを後から見返しても理解できるようにする。
   // RNG専用モードの時間帯バイパス情報は、1時間に1回だけ出力してログの氾濫を防ぎつつ、
   // 「何時台に24時間化していたか」を後から追跡できるようにする。
   // 日付と時間の両方をstaticで保持し、翌日同じ時刻になった場合も再度1回だけ出力する。
   static int lastBypassHourLogged = -1;
   static int lastBypassDayLogged  = -1;
   // サーバー時刻から当日(JST換算前)の日付を取得。TimeCurrent()/TimeTradeServer()のどちらも
   // 利用できない環境でビルドエラーにならないよう、関数化したGetServerTime()経由で取得する。
   // hourJSTは別途オフセット補正済みなので、日付はサーバー日を基準にする。
   int  curDay = (int)TimeCurrent();
   bool needBypassInfoLog = (curDay != lastBypassDayLogged || hourJST != lastBypassHourLogged);
   if(hoursBypassed && needBypassInfoLog)
   {
      // バイパス時は「info」扱いでVR/BBWのしきい値も併記し、24時間化している事実と閾値を1行で把握できるようにする
      LogRngSkip("hour_filter_disabled_for_rng_only", z, vr, ou, cur, hourJST, ouMin, ouMax, false, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
      // 同一時間帯での連投を避けるため、最後に出力した日付と時刻（JSTの時）を更新して抑制する
      lastBypassHourLogged = hourJST;
      lastBypassDayLogged  = curDay;
   }
   if(vr > InpVR_Thr)
   {
      // VR超過時も OUレンジとしきい値を併記し、入力の厳しさが原因かどうかを即座に判断できるようにする
      LogRngSkip("VR_over", z, vr, ou, cur, hourJST, ouMin, ouMax, true, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
      return;                        // VR上限超過ならボラ過多として除外（緩めた上限）
   }
   // OU判定は入力値の大小関係を自動修正し、浮動小数の誤差で弾かれないよう緩衝を設ける。
   if(!(ou + ouTol >= ouMin && ou - ouTol <= ouMax))
   {
      // 入力設定と実測OUを残して、なぜ弾かれたのかを後から検証しやすくする
      // OUの下限/上限と一致しない場合は、設定レンジと実測値の両方をログに残して原因を可視化する
      LogRngSkip("OU_out_of_range", z, vr, ou, cur, hourJST, ouMin, ouMax, true, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
      return; // OUが許容レンジ外なら均衡不足として除外（幅を拡大）
   }

   // BB幅によるレンジ確認（幅/ATR <= InpBBW2ATR）。幅が広すぎる場合は“レンジに見えない”ので見送り。
   if(InpRngUseBBW)
   {
      double atr = ATR_M1[sh];
      if(atr<=0.0) return;
      double bbw = 4.0*STD_M1[sh]; // Bollinger ±2σ幅（上-下）。σが欠損するケースも考慮して簡潔に計算。
      if(bbw/atr > InpBBW2ATR)
      {
         // BB幅超過時もOUレンジを残し、時間帯・VR・OUのどこで落ちたかを同一フォーマットで追跡する
         // BB幅超過時は、許容比と実測比のどちらが適切か後で判断できるようにしきい値も併記する
         LogRngSkip("BBW_over", z, vr, ou, cur, hourJST, ouMin, ouMax, true, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
         return;
      }
   }

   // zトリガー：クロス（|z|が閾値を跨ぐ瞬間）か、閾値以上に張り付いた滞留（N本連続）で1回だけ発火させる
   bool zCross = (MathAbs(lastZ_forTrigger) < InpZ_in && MathAbs(z) >= InpZ_in);
   if(MathAbs(z) >= InpZ_in) zHoldCount++; else zHoldCount=0;
   bool zHold = (zHoldCount >= InpZHoldBars);
   lastZ_forTrigger = z; // 次回のクロス検出用に保持

   if(!(zCross || zHold))
   {
      if(InpRngDebugLog)
         PrintFormat("RNGDBG wait_trigger z=%.3f last=%.3f hold=%d cross=%s holdTrig=%s", z, lastZ_forTrigger, zHoldCount, zCross?"Y":"N", zHold?"Y":"N");
      return; // どちらのトリガーも満たさない場合は発注しない
   }

   // 方向決定：zがマイナス側ならBUY、プラス側ならSELL。絶対値で間引いた後に符号で分岐する。
   bool wantBuy  = (z <= -InpZ_in);
   bool wantSell = (z >=  InpZ_in);
   if(!wantBuy && !wantSell)
   {
      // 符号が弱く発注不可だったケースも OUレンジを含めて足並みを揃える
      // 符号不足で撃たない場合も、他のしきい値と合わせて確認できるようにVR/BBWしきい値を残す
      LogRngSkip("sign_not_strong_enough", z, vr, ou, cur, hourJST, ouMin, ouMax, true, InpVR_Thr, InpRngUseBBW?InpBBW2ATR:-1.0);
      return; // 閾値を跨いでいない場合（符号だけの小刻みな動き）はスキップ
   }

   // 価格要素
   MqlTick tk; SymbolInfoTick(sym, tk);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt     = SymbolInfoDouble(sym, SYMBOL_POINT);
   double stops  = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double freeze = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minPts = MathMax(stops, freeze);

   double spread = tk.ask - tk.bid;
   // オフセットを小さく保ちながら、閾値判定が出た時点の価格を基準にラダーを組む。
   // ここで得た offset はラダー全段の基準位置（段差はATR倍率で加算/減算）。
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

   // ラダー段数とロット配分を計算（段数は1〜2にクリップ）。過剰発注を防ぎつつ機会を増やす。
   int ladder = MathMax(1, MathMin(2, InpRngLadderCount));
   double lot1=InpLots, lot2=0.0;
   if(ladder==2)
   {
      lot1 = InpLots * (InpRngLadderPct1/100.0);
      lot2 = InpLots - lot1;
   }

   // ラダー再アンカー判定：同方向に既存指値があり、価格乖離＋クールダウンを満たす場合は一括で置き直す。
   int pendingBuy  = CountPendingByTagPrefix("RNG_BUYLIMIT");
   int pendingSell = CountPendingByTagPrefix("RNG_SELLLIMIT");
   bool allowBuy  = wantBuy;
   bool allowSell = wantSell;

   // BUY側の再アンカー可否判定
   if(wantBuy && pendingBuy>0)
   {
      // GetServerTime()でサーバー時間を参照し、TimeCurrent()未定義エラーを避ける
      bool cooled = (GetServerTime() - lastAnchorTimeBuy) >= (InpRngReanchorCooldown*60);
      double atrNow = ATR_M1[sh];
      double drift  = MathAbs(tk.bid - lastAnchorPriceBuy);
      bool drifted = (atrNow>0.0 && drift >= InpRngReanchorShiftATR*atrNow);
      if(cooled && drifted)
      {
         CancelAllPendingsByTag("RNG_BUYLIMIT"); // 方向限定で安全に置き直す
         pendingBuy=0;
      }
      else
      {
         if(InpRngDebugLog)
            PrintFormat("RNGDBG keep_buy_anchor cooled=%s drifted=%s drift=%.5f atr=%.5f", cooled?"Y":"N", drifted?"Y":"N", drift, atrNow);
         allowBuy=false; // 条件未達なら既存を維持し、新規発注しない
      }
   }

   // SELL側の再アンカー可否判定
   if(wantSell && pendingSell>0)
   {
      // GetServerTime()でサーバー時間を参照し、TimeCurrent()未定義エラーを避ける
      bool cooled = (GetServerTime() - lastAnchorTimeSell) >= (InpRngReanchorCooldown*60);
      double atrNow = ATR_M1[sh];
      double drift  = MathAbs(tk.ask - lastAnchorPriceSell);
      bool drifted = (atrNow>0.0 && drift >= InpRngReanchorShiftATR*atrNow);
      if(cooled && drifted)
      {
         CancelAllPendingsByTag("RNG_SELLLIMIT");
         pendingSell=0;
      }
      else
      {
         if(InpRngDebugLog)
            PrintFormat("RNGDBG keep_sell_anchor cooled=%s drifted=%s drift=%.5f atr=%.5f", cooled?"Y":"N", drifted?"Y":"N", drift, atrNow);
         allowSell=false;
      }
   }

   // BUYラダー配置
   if(allowBuy && pendingBuy<ladder)
   {
      double base = NormalizeDouble(tk.bid - offset, digits); // 基準アンカー
      double step = InpRngLadderStepATR * ATR_M1[sh];
      for(int i=0; i<ladder; ++i)
      {
         double price = NormalizeDouble(base - i*step, digits); // BUYは下方向にずらす
         // STOP/FREEZE距離：現在のBidより下に置くので (tk.bid - price) >= minPts*pt
         if(minPts>0 && (tk.bid - price) < minPts*pt)
            price = tk.bid - minPts*pt;

         double vol = (i==0 ? lot1 : lot2);
         if(vol <= 0.0) continue; // 0ロットは無意味なのでスキップ

         double sl = 0.0;
         if(InpRNG_UseSL && rngSL>0.0) sl = price - rngSL; // BuyLimitのSLは下側

         // GetServerTime()で有効期限の基準時刻を取得（TimeCurrent未定義によるビルド失敗を回避）
         datetime exp = GetServerTime() + (InpRngExpiryBars*60); // 有効期限を設定し、再発注の余地を作る
         bool ok = Trade.BuyLimit(vol, price, sym, sl, 0.0, ORDER_TIME_SPECIFIED, exp, "RNG_BUYLIMIT");
         if(!ok) Print("RNG BuyLimit失敗:", _LastError);
      }
      // 最後に基準価格と時刻を更新（再アンカー判定用）
      lastAnchorPriceBuy = tk.bid;
      // 再アンカー時刻もサーバー時計(TimeTradeServer)で記録する（マクロ経由で未定義エラーを防ぐ）
      lastAnchorTimeBuy  = GetServerTime();
      if(InpRngDebugLog)
         PrintFormat("RNGDBG buy_placed base=%.5f step=%.5f ladder=%d lot1=%.2f lot2=%.2f", base, step, ladder, lot1, lot2);
   }
   else if(InpRngDebugLog && wantBuy)
   {
      // 既存アンカー維持などでBUYを見送った理由を明示
      PrintFormat("RNGDBG buy_skipped pending=%d ladder=%d allow=%s", pendingBuy, ladder, allowBuy?"Y":"N");
   }

   // SELLラダー配置
   if(allowSell && pendingSell<ladder)
   {
      double base = NormalizeDouble(tk.ask + offset, digits);
      double step = InpRngLadderStepATR * ATR_M1[sh];
      for(int i=0; i<ladder; ++i)
      {
         double price = NormalizeDouble(base + i*step, digits); // SELLは上方向にずらす
         // STOP/FREEZE距離：現在のAskより上に置くので (price - tk.ask) >= minPts*pt
         if(minPts>0 && (price - tk.ask) < minPts*pt)
            price = tk.ask + minPts*pt;

         double vol = (i==0 ? lot1 : lot2);
         if(vol <= 0.0) continue;

         double sl = 0.0;
         if(InpRNG_UseSL && rngSL>0.0) sl = price + rngSL; // SellLimitのSLは上側

         // GetServerTime()で有効期限の基準時刻を取得（TimeCurrent未定義対策）
         datetime exp = GetServerTime() + (InpRngExpiryBars*60);
         bool ok = Trade.SellLimit(vol, price, sym, sl, 0.0, ORDER_TIME_SPECIFIED, exp, "RNG_SELLLIMIT");
         if(!ok) Print("RNG SellLimit失敗:", _LastError);
      }
      lastAnchorPriceSell = tk.ask;
      // 再アンカー時刻もサーバー時計(TimeTradeServer)で記録する（マクロ経由で未定義を回避）
      lastAnchorTimeSell  = GetServerTime();
      if(InpRngDebugLog)
         PrintFormat("RNGDBG sell_placed base=%.5f step=%.5f ladder=%d lot1=%.2f lot2=%.2f", base, step, ladder, lot1, lot2);
   }
   else if(InpRngDebugLog && wantSell)
   {
      PrintFormat("RNGDBG sell_skipped pending=%d ladder=%d allow=%s", pendingSell, ladder, allowSell?"Y":"N");
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
  // ブローカー時刻（TimeTradeServer）→ オフセットでUTC → JST(+9) へ変換して hour を返す。
  // 自動オフセットが不正確なブローカーもあるため、auto→手動の順で安全にフォールバックする。
  //====================================================================
  int CurrentHourJST()
  {
   // サーバー現在時刻をGetServerTime()で取得し、TimeCurrent/TimeTradeServerいずれか未定義の環境でもビルドできるようにする
   datetime nowSrv = GetServerTime();

   // 1) サーバー→UTCのオフセットを決定（自動取得→手動値の順で採用）
   //    TimeGMTOffset() は一部ブローカーで0を返す場合があるため、
   //    自動値が0で明らかにズレている場合に備え手動値も残す。
   double offsetHours = 0.0;
   if(InpAutoDetectBrokerOffset)
   {
      offsetHours = TimeGMTOffset()/3600.0; // 秒→時間
   }
   // 自動値が0で、手動で非0を指定している場合は手動値を優先
   if(MathAbs(offsetHours) < 1e-6 && InpBrokerUTCOffsetHours!=0)
      offsetHours = InpBrokerUTCOffsetHours;

   // 2) UTCに戻してからJST(+9)へ変換
   datetime nowUTC = (datetime)(nowSrv - offsetHours*60.0*60.0);
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

// コメントに指定タグを含む保留注文が現在存在するかを確認するヘルパー
// RNG指値の「毎M1置き直し」を避け、約定またはキャンセルまで据え置くために使用
bool HasPendingByTag(const string tag)
{
   int total=OrdersTotal();
   for(int i=0; i<total; ++i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0)               continue; // 無効チケットをスキップ
      if(!OrderSelect(ticket))    continue; // 選択できない場合は次へ
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue; // 他EA/手動は除外
      if(OrderGetString(ORDER_SYMBOL)!=sym)      continue; // 他シンボルは除外

      int type=(int)OrderGetInteger(ORDER_TYPE);
      // 成行ではなく保留注文のみを対象（指値・逆指値）
      if(type!=ORDER_TYPE_BUY_LIMIT && type!=ORDER_TYPE_SELL_LIMIT &&
         type!=ORDER_TYPE_BUY_STOP  && type!=ORDER_TYPE_SELL_STOP)
         continue;

      string c = OrderGetString(ORDER_COMMENT);
      if(StringFind(c, tag, 0) >= 0) return true; // タグを含めば存在
   }
   return false; // 見つからなければ未設置
}

// コメントの先頭が指定プレフィックスで始まる保留注文（指値/逆指値）の件数を返すヘルパー
// RNGのラダー制御で「同方向に何本残っているか」を数えるために使用する
int CountPendingByTagPrefix(const string prefix)
{
   int total=OrdersTotal();
   int cnt=0;
   for(int i=0; i<total; ++i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0)               continue;
      if(!OrderSelect(ticket))    continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL)!=sym)      continue;

      int type=(int)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_LIMIT && type!=ORDER_TYPE_SELL_LIMIT &&
         type!=ORDER_TYPE_BUY_STOP  && type!=ORDER_TYPE_SELL_STOP)
         continue; // 成行は対象外

      string c = OrderGetString(ORDER_COMMENT);
      if(StringFind(c, prefix, 0) == 0) cnt++;
   }
   return cnt;
}

// コメントに指定文字列を含む保留注文の件数を返すヘルパー。
// セルフレビュー用に「TRD系」「RNG系」の残数を簡易的に把握するために使用する。
int CountPendingBySubstring(const string needle)
{
   int total=OrdersTotal();
   int cnt=0;
   for(int i=0; i<total; ++i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0)               continue; // 無効チケットはスキップ
      if(!OrderSelect(ticket))    continue; // 選択できない場合は次へ
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue; // 本EA以外は対象外
      if(OrderGetString(ORDER_SYMBOL)!=sym)      continue; // シンボル違いも除外

      int type=(int)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_LIMIT && type!=ORDER_TYPE_SELL_LIMIT &&
         type!=ORDER_TYPE_BUY_STOP  && type!=ORDER_TYPE_SELL_STOP)
         continue; // 成行は数えない

      string c = OrderGetString(ORDER_COMMENT);
      if(StringFind(c, needle, 0) >= 0) cnt++; // 部分一致でカウント
   }
   return cnt;
}

//=====================================================================
// セルフレビュー：モード/レジーム/抑止状態と保留注文状況をH1ごとに出力し、
// 「どの条件で撃っていないのか」を後から追跡しやすくする。
// backtestでもログで確認できるよう、H1確定ごとに1回のみ出力する。
//=====================================================================
void SelfReviewStatus(Regime regime, bool trdEnabled, bool rngEnabled, bool bothEnabled)
{
   static datetime lastPrintedH1=0; // 同一H1バーでの重複出力防止
   datetime curH1=iTime(sym, TF_H1, 0);
   if(curH1==lastPrintedH1) return;
   lastPrintedH1 = curH1;

   // モード文字列（InpModuleSwitch）を人間が見やすい形に整形
   string modeStr;
   switch(InpModuleSwitch)
   {
      case MODE_BOTH:     modeStr = "BOTH"; break;
      case MODE_TRD_ONLY: modeStr = "TRD_ONLY"; break;
      case MODE_RNG_ONLY: modeStr = "RNG_ONLY"; break;
      case MODE_ALL_OFF:  modeStr = "ALL_OFF"; break;
      default:            modeStr = "UNKNOWN"; break;
   }

   // 現在の状態を収集
   string regStr      = (regime==REG_TRD?"TRD":"RNG");
   string lastRegStr  = (lastRegime==REG_TRD?"TRD":"RNG");
   bool   hasPos      = AnyOpenPosition();
   int    pendTRD     = CountPendingBySubstring("TRD_");
   int    pendRngBuy  = CountPendingBySubstring("RNG_BUYLIMIT");
   int    pendRngSell = CountPendingBySubstring("RNG_SELLLIMIT");

   // 抑止状態や強制レジームの有無をまとめてログ出力
   PrintFormat("セルフレビュー[H1] mode=%s TRD有効=%s RNG有効=%s gate使用=%s regime=%s lastRegime=%s inhibit=%s ポジ有=%s TRD保留=%d RNG保留(B/S)=%d/%d",
               modeStr,
               trdEnabled?"true":"false",
               rngEnabled?"true":"false",
               bothEnabled?"true":"false",
               regStr,
               lastRegStr,
               inhibitEntryThisH1Bar?"true":"false",
               hasPos?"true":"false",
               pendTRD,
               pendRngBuy,
               pendRngSell);
}
