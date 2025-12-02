//+------------------------------------------------------------------+
//|                                           HarmonicFlowTrader.mq5 |
//|                               Trend & Channel Pullback Strategy |
//|                                  実装：仕様書に基づく完全版EA     |
//+------------------------------------------------------------------+
#property copyright "TS"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| 仕様準拠：                                                       |
//| ・MT5 / MQL5 専用EA                                              |
//| ・OnInit / OnDeinit / OnTick を実装                              |
//| ・CTradeのみで注文操作                                          |
//| ・H1の確定足(shift=1)を参照し、M5で発注                          |
//| ・全判定で未確定バー(shift=0)は使用しない                       |
//| ・通貨ペア依存ロジック禁止。桁数は _Digits で自動取得           |
//| ・ニュースフィルタはモック実装                                  |
//| ・同時保有は1ポジション/1指値まで                               |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>

// 取引クラスはCTradeのみを使用
CTrade g_trade;

//+------------------------------------------------------------------+
//| 入力パラメータ群（仕様書準拠）                                   |
//+------------------------------------------------------------------+
input double Inp_FixedLot = 0.10;                       // 固定ロット
input bool   Inp_UseRiskPercent = false;                // 残高割合でロット計算
input double Inp_RiskPercent = 1.0;                     // リスク％
input bool   Inp_AllowNewLong = true;                   // 新規ロング許可
input bool   Inp_AllowNewShort = true;                  // 新規ショート許可
input uint   Inp_Magic = 123456;                        // マジックナンバー
input string Inp_Comment = "TrendChannelEA";           // コメント

// 時間帯・ニュースフィルタ
input bool   Inp_UseSessionFilter = true;               // セッションフィルタ使用
input bool   Inp_AllowTokyo = true;                     // 東京時間許可
input bool   Inp_AllowLondon = true;                    // ロンドン時間許可
input bool   Inp_AllowNY = true;                        // NY時間許可
input bool   Inp_UseTimeFilter = false;                 // 任意時間フィルタ使用
input int    Inp_TradeStartHour = 0;                    // 取引開始時刻
input int    Inp_TradeEndHour = 24;                     // 取引終了時刻
input bool   Inp_UseNewsFilter = false;                 // ニュースフィルタ使用
input int    Inp_NewsMajorMinutes = 60;                 // 重要指標の前後禁止分数
input int    Inp_NewsMediumMinutes = 30;                // 中程度指標
input int    Inp_NewsMinorMinutes = 5;                  // 軽微指標

// スプレッド・安全マージン
input bool   Inp_UseSpreadFilter = true;                // スプレッド制御
input double Inp_MaxSpreadPoints = 0;                   // 最大スプレッド (0で自動)
input double Inp_SpreadMultiplier = 1.5;                // 自動計算倍率
input double Inp_SpreadSafetyBuffer = 1.6;              // Stop/Freeze安全倍率

// トリガー・決済関連
input double Inp_TP_Ratio_First = 1.5;                  // TP距離（R倍率）
input double Inp_SL_ATR_Ratio = 1.0;                    // SLをATR倍率で算出
input double Inp_MiniTP_R_BO = 0.60;                    // トレンド/バンド部分利確R
input double Inp_MiniTP_R_BO_Pullback = 0.55;           // チャネル押し目R
input double Inp_MiniTP_Frac_BO = 0.30;                 // 部分利確割合（通常）
input double Inp_MiniTP_Frac_Pullback = 0.35;           // 部分利確割合（チャネル）
input double Inp_BE_Trigger_R = 0.80;                   // BE移動開始R
input double Inp_BE_Offset_R = 0.00;                    // 建値ずらしR
input double Inp_TimeStop_Trend_Hours = 2.0;            // トレンド保有時間制限
input double Inp_TimeStop_Pullback_Hours = 1.6;         // チャネル保有時間制限

// デバッグ
input bool   Inp_DebugLog = true;                       // Print出力の有無

//+------------------------------------------------------------------+
//| 内部で使用する定数・構造体                                       |
//+------------------------------------------------------------------+
enum EntryType
  {
   ENTRY_NONE = 0,
   ENTRY_BAND = 1,
   ENTRY_CHANNEL = 2
  };

struct H1Context
  {
   double   close1;
   double   high1;
   double   low1;
   double   open1;
   double   ma20;
   double   ma200;
   double   atr14;
   double   bbUpper;
   double   bbLower;
   double   bbWidth;
   double   ma20Slope;
   double   ma200Slope;
   datetime time1;
  };

struct PositionState
  {
   long     ticket;
   bool     partialDone;
   bool     beDone;
   datetime entryTime;
   EntryType type;
  };

// グローバル状態
PositionState g_positionState = {0,false,false,0,ENTRY_NONE};
double g_spreadHistory[500];              // スプレッド履歴（最大500件）
int    g_spreadCount = 0;                 // 履歴件数

// インジケータハンドル（H1）
int g_ma20H1Handle = INVALID_HANDLE;
int g_ma200H1Handle = INVALID_HANDLE;
int g_atrH1Handle = INVALID_HANDLE;
// ボリンジャーバンドは単一ハンドルで上限(バッファ0)・下限(バッファ2)を取得する
int g_bbHandle = INVALID_HANDLE;

// インジケータハンドル（M5）
int g_ma20M5Handle = INVALID_HANDLE;
int g_ma50M5Handle = INVALID_HANDLE;
int g_atrM5Handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| デバッグ出力用のヘルパー                                        |
//+------------------------------------------------------------------+
void DebugPrint(const string message)
  {
   // デバッグが有効な場合のみPrintを実行し、ログを過剰に出さないように制御
   if(Inp_DebugLog)
      Print(message);
  }

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- インジケータハンドルの生成（失敗時はエラー返却）
   g_ma20H1Handle = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   g_ma200H1Handle = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_SMA, PRICE_CLOSE);
   g_atrH1Handle = iATR(_Symbol, PERIOD_H1, 14);
   // iBandsはMQL5ではMODE指定不要。6引数で作成し、CopyBufferのバッファ番号で上下を区別する
   // 第4引数はシフト、第5引数が偏差(Deviation)であるため、順序を誤るとコンパイルエラーになる点に注意
   g_bbHandle = iBands(_Symbol, PERIOD_H1, 20, 0, 2.0, PRICE_CLOSE);

   g_ma20M5Handle = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_SMA, PRICE_CLOSE);
   g_ma50M5Handle = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_SMA, PRICE_CLOSE);
   g_atrM5Handle = iATR(_Symbol, PERIOD_M5, 14);

   // いずれかのハンドルが無効ならエラー終了
   if(g_ma20H1Handle==INVALID_HANDLE || g_ma200H1Handle==INVALID_HANDLE || g_atrH1Handle==INVALID_HANDLE ||
      g_bbHandle==INVALID_HANDLE ||
      g_ma20M5Handle==INVALID_HANDLE || g_ma50M5Handle==INVALID_HANDLE || g_atrM5Handle==INVALID_HANDLE)
     {
      DebugPrint("インジケータハンドル生成に失敗しました。");
      return(INIT_FAILED);
     }

   // 取引設定（マジックナンバー設定）
   g_trade.SetExpertMagicNumber((int)Inp_Magic);
   g_trade.SetDeviationInPoints(20); // デフォルトの滑り幅を控えめに設定

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- ハンドル解放（念のため）
   IndicatorRelease(g_ma20H1Handle);
   IndicatorRelease(g_ma200H1Handle);
   IndicatorRelease(g_atrH1Handle);
   // ボリンジャーバンドのハンドルを解放
   IndicatorRelease(g_bbHandle);

   IndicatorRelease(g_ma20M5Handle);
   IndicatorRelease(g_ma50M5Handle);
   IndicatorRelease(g_atrM5Handle);
  }

//+------------------------------------------------------------------+
//| 時間帯判定（セッションフィルタ）                                 |
//+------------------------------------------------------------------+
bool AllowBySession()
  {
   if(!Inp_UseSessionFilter)
      return(true);

   datetime now = TimeCurrent();
   MqlDateTime mt;
   TimeToStruct(now, mt);
   int hour = mt.hour;

   // サーバー時間ベースで東京/ロンドン/NYの許可を確認
   if(hour>=8 && hour<16 && !Inp_AllowTokyo)
      return(false);
   if(hour>=16 && hour<24 && !Inp_AllowLondon)
      return(false);
   if(hour>=0 && hour<8 && !Inp_AllowNY)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| 任意時間フィルタ                                                 |
//+------------------------------------------------------------------+
bool AllowByTimeWindow()
  {
   if(!Inp_UseTimeFilter)
      return(true);

   datetime now = TimeCurrent();
   MqlDateTime mt;
   TimeToStruct(now, mt);
   int hour = mt.hour;

   // 開始<=終了の場合は単純比較。24時間表現のため境界を考慮
   if(Inp_TradeStartHour <= Inp_TradeEndHour)
     {
      return(hour >= Inp_TradeStartHour && hour < Inp_TradeEndHour);
     }
   else
     {
      // 例えば22-4時のように跨るケース
      return(hour >= Inp_TradeStartHour || hour < Inp_TradeEndHour);
     }
  }

//+------------------------------------------------------------------+
//| ニュースフィルタ（モック：常に取引許可）                         |
//| 仕様に従い、フックのみ実装し将来差し替え可能にする               |
//+------------------------------------------------------------------+
bool AllowByNews()
  {
   if(!Inp_UseNewsFilter)
      return(true);

   // 実データがないため常に許可。ただし将来の拡張ポイントとしてコメントを残す
   // ニュースの前後禁止時間(Inp_NewsMajorMinutes等)を参照して
   // 外部ソースからイベント時刻を受け取り、現在時刻との比較で制御する予定。
   return(true);
  }

//+------------------------------------------------------------------+
//| スプレッド履歴の更新と許容スプレッド計算                         |
//+------------------------------------------------------------------+
double CalcAllowedSpreadPoints()
  {
   // 現在のスプレッドを履歴に追加し、最大500件に収める
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(g_spreadCount < ArraySize(g_spreadHistory))
     {
      g_spreadHistory[g_spreadCount++] = spread;
     }
   else
     {
      // 上限を超えた場合はFIFO的にシフトし、直近500件を維持
      for(int i=1; i<g_spreadCount; ++i)
         g_spreadHistory[i-1] = g_spreadHistory[i];
      g_spreadHistory[g_spreadCount-1] = spread;
     }

   // ユーザー指定があればそれを優先
   if(Inp_MaxSpreadPoints > 0.0)
      return(Inp_MaxSpreadPoints);

   // 統計的80%分位を算出（履歴が少ない場合は現在値を許容値とする）
   if(g_spreadCount < 10)
      return(spread * Inp_SpreadMultiplier);

   double temp[];
   ArrayResize(temp, g_spreadCount);
   ArrayCopy(temp, g_spreadHistory, 0, 0, g_spreadCount);
   // MQL5のArraySortは配列のみを引数に取る1引数版で、常に先頭次元を昇順に並べ替える
   //（MQL4風の開始位置・件数を渡すシグネチャは存在しないため、1引数に揃える）
   // WHOLE_ARRAY未定義環境でも問題なく動作し、常に全件ソートされることを明示
   ArraySort(temp);

   int index = (int)MathFloor(0.8 * (g_spreadCount - 1));
   double perc80 = temp[index];
   return(perc80 * Inp_SpreadMultiplier);
  }

//+------------------------------------------------------------------+
//| スプレッドフィルタの最終判定                                     |
//+------------------------------------------------------------------+
bool AllowBySpread(double &currentSpread)
  {
   currentSpread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   double allowed = CalcAllowedSpreadPoints();
   if(!Inp_UseSpreadFilter)
      return(true);

   if(currentSpread <= allowed)
      return(true);

   DebugPrint(StringFormat("スプレッド制限により取引不可: 現在=%.1f, 許容=%.1f", currentSpread, allowed));
   return(false);
  }

//+------------------------------------------------------------------+
//| StopLevel/FreezeLevelを考慮した最小距離取得                      |
//+------------------------------------------------------------------+
double MinDistancePrice()
  {
   // StopLevelとFreezeLevelはポイント単位で得られるため、Pointと係数で距離算出
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int strictLevel = MathMax(stopLevel, freezeLevel);
   double minPts = strictLevel * Inp_SpreadSafetyBuffer;
   return(minPts * _Point);
  }

//+------------------------------------------------------------------+
//| ボリューム桁数をステップから算出                                  |
//| SYMBOL_VOLUME_DIGITSを使わず、stepから安全に桁数を計算する        |
//+------------------------------------------------------------------+
int VolumeDigitsFromStep(const double step)
  {
   // stepが0以下の場合は2桁にフォールバックし、ゼロ除算やlog計算の失敗を防止
   if(step <= 0.0)
      return(2);

   // 例えばstep=0.01なら2桁、0.001なら3桁という具合に桁数を求める
   double logValue = -MathLog10(step);
   int digits = (int)MathMax(0.0, MathRound(logValue));
   return(digits);
  }

//+------------------------------------------------------------------+
//| H1のインジケータと価格をまとめて取得                             |
//+------------------------------------------------------------------+
bool UpdateH1Context(H1Context &ctx)
  {
   // 最新の確定足(shift=1)のみを取得するため、CopyRatesの2本分を確保
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_H1, 1, 2, rates) != 2)
     {
      DebugPrint("H1の価格取得に失敗しました。");
      return(false);
     }

   double ma20[7], ma200[7], atr[3], bbUpper[3], bbLower[3];
   int copied1 = CopyBuffer(g_ma20H1Handle, 0, 1, 7, ma20);
   int copied2 = CopyBuffer(g_ma200H1Handle, 0, 1, 7, ma200);
   int copied3 = CopyBuffer(g_atrH1Handle, 0, 1, 3, atr);
   // ボリンジャーバンド上限はバッファ0、下限はバッファ2を使用する
   int copied4 = CopyBuffer(g_bbHandle, 0, 1, 3, bbUpper);
   int copied5 = CopyBuffer(g_bbHandle, 2, 1, 3, bbLower);

   if(copied1<7 || copied2<7 || copied3<3 || copied4<3 || copied5<3)
     {
      DebugPrint("H1インジケータの取得に失敗しました。");
      return(false);
     }

   // 傾きは3本差分/6本差分で近似（仕様の通り）
   ctx.close1 = rates[0].close;
   ctx.high1 = rates[0].high;
   ctx.low1 = rates[0].low;
   ctx.open1 = rates[0].open;
   ctx.time1 = rates[0].time;
   ctx.ma20 = ma20[0];
   ctx.ma200 = ma200[0];
   ctx.atr14 = atr[0];
   ctx.bbUpper = bbUpper[0];
   ctx.bbLower = bbLower[0];
   ctx.bbWidth = (ctx.bbUpper - ctx.bbLower) / ctx.ma20;
   ctx.ma20Slope = ma20[0] - ma20[3];   // 3本差分
   ctx.ma200Slope = ma200[0] - ma200[6]; // 6本差分

   return(true);
  }

//+------------------------------------------------------------------+
//| M5の価格/インジケータを取得（確定足）                            |
//+------------------------------------------------------------------+
bool GetM5Values(double &close1, double &ma20, double &ma50, double &atr14)
  {
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, rates) != 1)
     {
      DebugPrint("M5の価格取得に失敗しました。");
      return(false);
     }
   double ma20buf[2], ma50buf[2], atrbuf[2];
   if(CopyBuffer(g_ma20M5Handle, 0, 1, 1, ma20buf) != 1)
     {
      DebugPrint("M5 MA20取得に失敗しました。");
      return(false);
     }
   if(CopyBuffer(g_ma50M5Handle, 0, 1, 1, ma50buf) != 1)
     {
      DebugPrint("M5 MA50取得に失敗しました。");
      return(false);
     }
   if(CopyBuffer(g_atrM5Handle, 0, 1, 1, atrbuf) != 1)
     {
      DebugPrint("M5 ATR取得に失敗しました。");
      return(false);
     }

   close1 = rates[0].close;
   ma20 = ma20buf[0];
   ma50 = ma50buf[0];
   atr14 = atrbuf[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| チャネル境界の近似（単純な高値/安値レンジを直線化せず使用）       |
//+------------------------------------------------------------------+
bool ComputeChannel(double &upper, double &lower)
  {
   // 直近H1の高値・安値を50本集計し、チャネルの目安とする
   MqlRates rates[];
   int count = CopyRates(_Symbol, PERIOD_H1, 1, 50, rates);
   if(count < 10)
     {
      DebugPrint("チャネル計算用のH1データが不足しています。");
      return(false);
     }

   double highMax = rates[0].high;
   double lowMin = rates[0].low;
   for(int i=1; i<count; ++i)
     {
      if(rates[i].high > highMax) highMax = rates[i].high;
      if(rates[i].low < lowMin) lowMin = rates[i].low;
     }
   upper = highMax;
   lower = lowMin;
   return(true);
  }

//+------------------------------------------------------------------+
//| ロット計算（残高リスク or 固定ロット）                           |
//+------------------------------------------------------------------+
double CalculateLot(double slDistance)
  {
   // slDistanceは価格差。リスクロット方式の場合は金額からロットを算出
   if(!Inp_UseRiskPercent || slDistance <= 0.0)
      return(Inp_FixedLot);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      return(Inp_FixedLot);

   // 残高取得はMQL5ネイティブのAccountInfoDoubleを使用し、互換性のないAccountBalance呼び出しを避ける
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (Inp_RiskPercent/100.0);
   double valuePerLot = (slDistance / tickSize) * tickValue;
   if(valuePerLot <= 0.0)
      return(Inp_FixedLot);

   double lot = riskMoney / valuePerLot;

   // ブローカーの許容範囲に丸める
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int volumeDigits = VolumeDigitsFromStep(step);
   // 桁数はstepから算出することで、ブローカー固有の桁数でも正しく正規化する
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot/step) * step;
   lot = NormalizeDouble(lot, volumeDigits);
   return(lot);
  }

//+------------------------------------------------------------------+
//| ポジション/オーダー件数の確認（同時1つ制御）                     |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   // MQL5ではシンボル指定のPositionSelectで現在のシンボル保有有無を即判定できる
   // ・インデックス走査だとプラットフォーム差分でSelectByIndexが利用不可となる場合がある
   // ・当EAは同一シンボルで同時1ポジションを前提としているため、この単純判定で十分
   if(!PositionSelect(_Symbol))
      return(false);

   // PositionSelect成功時のみチケットを取得し、0でなければ保有中と確定する
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   return(ticket>0);
  }

bool HasPendingOrder()
  {
   // MT5ではOrderSelectのオーバーロードが環境差で異なるため、チケット取得→選択の順で安全に走査する
   for(int i=0;i<OrdersTotal();++i)
     {
      // まずチケット番号を取得し、無効な場合はスキップする
      ulong ticket = OrderGetTicket(i);
      if(ticket==0)
         continue;

      // チケットを指定して選択し、取得できなければ次へ
      if(!OrderSelect(ticket))
         continue;

      // シンボル一致かつ有効チケットなら既存指値とみなす
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && ticket>0)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| エントリー種別をコメント文字列へ埋め込み・復元                   |
//+------------------------------------------------------------------+
string ComposeComment(EntryType type)
  {
   string suffix = (type==ENTRY_BAND ? "BAND" : (type==ENTRY_CHANNEL ? "CHANNEL" : "NONE"));
   return(StringFormat("%s|%s", Inp_Comment, suffix));
  }

EntryType ParseEntryType(const string comment)
  {
   int pos = StringFind(comment, "|");
   if(pos < 0) return(ENTRY_NONE);
   string tag = StringSubstr(comment, pos+1);
   if(tag=="BAND") return(ENTRY_BAND);
   if(tag=="CHANNEL") return(ENTRY_CHANNEL);
   return(ENTRY_NONE);
  }

//+------------------------------------------------------------------+
//| ポジション状態の同期（再起動でも状態を復元）                     |
//+------------------------------------------------------------------+
void SyncPositionState()
  {
   // シンボル指定でポジションを直接選択し、選択できない場合は状態を初期化する
   // ・SelectByIndexを使わないことで、インデックス走査が禁止されている環境でも動作を保証
   // ・単一シンボル運用前提のため、PositionSelect(_Symbol)のみで十分に復元可能
   if(PositionSelect(_Symbol))
     {
      // 選択成功時はチケット・エントリー時間・コメントを復元し、部分利確/BEフラグも再評価待ちに戻す
      g_positionState.ticket = (long)PositionGetInteger(POSITION_TICKET);
      g_positionState.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
      g_positionState.type = ParseEntryType(PositionGetString(POSITION_COMMENT));
      g_positionState.partialDone = false; // 再起動後にMiniTPを再判定させる
      g_positionState.beDone = false;      // 再起動後にBE移動を再判定させる
      return;
     }

   // 選択に失敗（=保有なし）の場合は状態を全て初期化する
   g_positionState.ticket = 0;
   g_positionState.entryTime = 0;
   g_positionState.type = ENTRY_NONE;
   g_positionState.partialDone = false;
   g_positionState.beDone = false;
  }

//+------------------------------------------------------------------+
//| シグナル判定                                                     |
//+------------------------------------------------------------------+
bool EvaluateSignal(const H1Context &h1, double m5Close, double m5MA20, double m5MA50,
                    double m5ATR, bool &isBuy, EntryType &type)
  {
   isBuy = false;
   type = ENTRY_NONE;

   // トレンド判定：MA20>MA200 かつ傾きが上向きで強気、逆なら弱気
   bool bullishTrend = (h1.ma20 > h1.ma200) && (h1.ma20Slope > 0.0);
   bool bearishTrend = (h1.ma20 < h1.ma200) && (h1.ma20Slope < 0.0);

   // バンド押し目：価格が下側バンドに近い場合
   double bandRange = h1.bbUpper - h1.bbLower;
   double lowerThreshold = h1.bbLower + bandRange * 0.25; // 下位25%ゾーン
   double upperThreshold = h1.bbUpper - bandRange * 0.25; // 上位25%ゾーン

   // チャネル押し目：広いレンジを使った単純チャネル
   double channelUpper, channelLower;
   bool hasChannel = ComputeChannel(channelUpper, channelLower);
   double channelRange = (hasChannel ? (channelUpper - channelLower) : 0.0);
   double channelLowerZone = channelLower + channelRange * 0.2;
   double channelUpperZone = channelUpper - channelRange * 0.2;

   // M5トリガーはMA20とMA50のクロス方向で確認（必ず確定足使用）
   bool m5BullTrigger = (m5Close > m5MA20) && (m5MA20 > m5MA50);
   bool m5BearTrigger = (m5Close < m5MA20) && (m5MA20 < m5MA50);

   // ロング条件：トレンド上向き、下側バンドまたはチャネル下部＋M5強気
   if(bullishTrend && m5BullTrigger)
     {
      if(h1.close1 <= lowerThreshold)
        {
         isBuy = true;
         type = ENTRY_BAND;
         return(true);
        }
      if(hasChannel && h1.close1 <= channelLowerZone)
        {
         isBuy = true;
         type = ENTRY_CHANNEL;
         return(true);
        }
     }

   // ショート条件：トレンド下向き、上側バンドまたはチャネル上部＋M5弱気
   if(bearishTrend && m5BearTrigger)
     {
      if(h1.close1 >= upperThreshold)
        {
         isBuy = false;
         type = ENTRY_BAND;
         return(true);
        }
      if(hasChannel && h1.close1 >= channelUpperZone)
        {
         isBuy = false;
         type = ENTRY_CHANNEL;
         return(true);
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| SL/TPを計算（StopLevel安全距離を自動適用）                        |
//+------------------------------------------------------------------+
void CalculateSLTP(bool isBuy, double atrM5, double &sl, double &tp, double &slDistance)
  {
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = _Point;
   double minDistPrice = MinDistancePrice();

   // ATR基準のSL距離（仕様：固定倍率）
   slDistance = atrM5 * Inp_SL_ATR_Ratio;
   // 最低距離を確保
   slDistance = MathMax(slDistance, minDistPrice);

   if(isBuy)
     {
      sl = price - slDistance;
      tp = price + (slDistance * Inp_TP_Ratio_First);
     }
   else
     {
      sl = price + slDistance;
      tp = price - (slDistance * Inp_TP_Ratio_First);
     }

   // 価格の桁をシンボル桁数に整形
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
  }

//+------------------------------------------------------------------+
//| MiniTP・BE移動・タイムストップの管理                             |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   // ポジションがなければ何もしない
   if(!PositionSelect(_Symbol))
     {
      // ポジションなし状態を同期
      if(g_positionState.ticket!=0)
         SyncPositionState();
      return;
     }

   // チケットと基本情報
   long ticket = (long)PositionGetInteger(POSITION_TICKET);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   int direction = (int)PositionGetInteger(POSITION_TYPE);

   // 状態が新規ポジションと異なる場合は同期
   if(ticket != g_positionState.ticket)
     {
      SyncPositionState();
     }

   // SL距離を算出（R計算用）
   double slDistance = MathAbs(entryPrice - sl);
   if(slDistance <= 0.0)
      return; // SL未設定の場合は管理不可

   double currentPrice = (direction==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                       : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double rValue = 0.0;
   if(direction==POSITION_TYPE_BUY)
      rValue = (currentPrice - entryPrice) / slDistance;
   else
      rValue = (entryPrice - currentPrice) / slDistance;

   // 部分利確判定
    double partialTrigger = (g_positionState.type==ENTRY_CHANNEL) ? Inp_MiniTP_R_BO_Pullback : Inp_MiniTP_R_BO;
    double partialFrac = (g_positionState.type==ENTRY_CHANNEL) ? Inp_MiniTP_Frac_Pullback : Inp_MiniTP_Frac_BO;
    if(!g_positionState.partialDone && rValue >= partialTrigger && volume > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
      {
       double closeVolume = volume * partialFrac;
       closeVolume = MathMax(closeVolume, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
       // ボリューム桁はステップから求めることで、シンボル依存の桁数でも正しく丸める
       int volumeDigits = VolumeDigitsFromStep(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
       closeVolume = NormalizeDouble(closeVolume, volumeDigits);
       if(g_trade.PositionClosePartial(ticket, closeVolume))
         {
          DebugPrint(StringFormat("MiniTP発動: ticket=%d, R=%.2f, partial=%.2f", ticket, rValue, closeVolume));
          g_positionState.partialDone = true;
         }
     }

   // 建値移動判定
   if(!g_positionState.beDone && rValue >= Inp_BE_Trigger_R)
     {
      double newSL = entryPrice;
      if(direction==POSITION_TYPE_BUY)
         newSL = entryPrice + (Inp_BE_Offset_R * slDistance);
      else
         newSL = entryPrice - (Inp_BE_Offset_R * slDistance);

      // 最低距離を確保してから設定
      double minDist = MinDistancePrice();
      // 三項演算子内で改行されないよう1行にまとめ、SYMBOL_ASK/SYMBOL_BIDの識別子が壊れないようにする
      double basePrice = (direction==POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)  // BUYの場合はBid基準
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK); // SELLの場合はAsk基準
      if(direction==POSITION_TYPE_BUY && (basePrice - newSL) < minDist)
         newSL = basePrice - minDist;
      if(direction==POSITION_TYPE_SELL && (newSL - basePrice) < minDist)
         newSL = basePrice + minDist;

      newSL = NormalizeDouble(newSL, _Digits);
      if(g_trade.PositionModify(ticket, newSL, tp))
        {
         DebugPrint(StringFormat("BE移動: ticket=%d, newSL=%.5f", ticket, newSL));
         g_positionState.beDone = true;
        }
     }

   // タイムストップ判定
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   double holdHours = (double)(TimeCurrent() - openTime) / 3600.0;
   double limitHours = (g_positionState.type==ENTRY_CHANNEL) ? Inp_TimeStop_Pullback_Hours : Inp_TimeStop_Trend_Hours;
   if(holdHours >= limitHours)
     {
      DebugPrint(StringFormat("TimeStop発動: ticket=%d, 経過時間=%.2f", ticket, holdHours));
      g_trade.PositionClose(ticket);
      SyncPositionState();
     }
  }

//+------------------------------------------------------------------+
//| 新規エントリー処理                                               |
//+------------------------------------------------------------------+
void TryEntry()
  {
   // 既存ポジション/オーダーがある場合は新規エントリー禁止
   if(HasOpenPosition() || HasPendingOrder())
      return;

   // フィルタチェック
   if(!AllowBySession())
      { DebugPrint("セッションフィルタでブロック"); return; }
   if(!AllowByTimeWindow())
      { DebugPrint("時間帯フィルタでブロック"); return; }
   if(!AllowByNews())
      { DebugPrint("ニュースフィルタでブロック"); return; }

   double currentSpread;
   if(!AllowBySpread(currentSpread))
      return;

   // H1コンテキストとM5値を取得
   H1Context h1;
   double m5Close, m5MA20, m5MA50, m5ATR;
   if(!UpdateH1Context(h1)) return;
   if(!GetM5Values(m5Close, m5MA20, m5MA50, m5ATR)) return;

   bool isBuy; EntryType type;
   if(!EvaluateSignal(h1, m5Close, m5MA20, m5MA50, m5ATR, isBuy, type))
      return;

   // 方向許可チェック
   if(isBuy && !Inp_AllowNewLong) return;
   if(!isBuy && !Inp_AllowNewShort) return;

   // SL/TP計算
   double sl, tp, slDistance;
   CalculateSLTP(isBuy, m5ATR, sl, tp, slDistance);

   double volume = CalculateLot(slDistance);
   if(volume <= 0.0)
      { DebugPrint("ロット計算に失敗"); return; }

   // 発注処理。価格はBid/Askを正確に使用
   bool result = false;
   if(isBuy)
      result = g_trade.Buy(volume, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, ComposeComment(type));
   else
      result = g_trade.Sell(volume, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, ComposeComment(type));

   if(result)
     {
      DebugPrint(StringFormat("エントリー成功: %s, volume=%.2f, SL=%.5f, TP=%.5f, R距離=%.5f", isBuy?"BUY":"SELL", volume, sl, tp, slDistance));
      // 状態初期化
      g_positionState.ticket = (long)g_trade.ResultDeal();
      g_positionState.partialDone = false;
      g_positionState.beDone = false;
      g_positionState.entryTime = TimeCurrent();
      g_positionState.type = type;
     }
   else
     {
      DebugPrint(StringFormat("エントリー失敗: %s, エラー=%d", isBuy?"BUY":"SELL", GetLastError()));
     }
  }

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 各ティックでスプレッド履歴更新を行い、以降のフィルタに活用する
   CalcAllowedSpreadPoints();

   // 既存ポジションの管理（MiniTP/BE/TimeStop）
   ManagePosition();

   // 新規エントリー検討
   TryEntry();
  }

//+------------------------------------------------------------------+
