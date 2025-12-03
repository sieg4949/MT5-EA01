関数名,引数と用途（この仕様書における役割）
CopyRates,"int CopyRates(symbol, timeframe, start, count, rates[])用途： H1およびM5の「高値・安値・終値」を取得するために使用。特にH1のスイングハイ/ロー検出や、M5の包み足・ピンバー判定に必須。"
CopyBuffer,"int CopyBuffer(handle, buffer_num, start, count, buffer[])用途： iMA, iATRなどのインジケーター計算値を取得する。特に**H1 ATRの過去20本分（中央値計算用）**の一括取得に使用。"
ArraySetAsSeries,"bool ArraySetAsSeries(array[], true)用途： 配列のインデックス [0] を「最新」にするために必須。これを忘れると過去データ計算（スロープ算出など）が狂います。"
ArrayMaximum,"int ArrayMaximum(array[], start, count)用途： H1のSwingHigh検出（過去50本の最高値の位置特定）に使用。"
ArrayMinimum,"int ArrayMinimum(array[], start, count)用途： H1のSwingLow検出に使用。"
ArraySort,void ArraySort(array[])用途： ATRの中央値を求めるために使用。CopyBufferで取得したATR配列を一旦コピーし、ソートして真ん中の値を取るロジックで使います。
ArrayCopy,"int ArrayCopy(dst[], src[])用途： ソート等のために配列を複製する際に使用（元データを壊さないため）。"
MathMax / MathMin,"double MathMax(val1, val2)用途： チャネル品質計算（Clamp処理）や、エントリーバッファの縮小計算で使用。"
MathAbs,double MathAbs(value)用途： スロープの傾きの絶対値判定や、チャネル平行性チェックに使用。
TimeToStruct,"void TimeToStruct(datetime time, MqlDateTime& dt_struct)用途： サーバー時間を MqlDateTime 構造体に変換し、.hour （何時か）を取得してセッションフィルタを判定する。"
TimeCurrent,datetime TimeCurrent()用途： 現在時刻の取得。**Pending Orderの有効期限(TTL)**の設定や、ポジション保有時間の計算に使用。
PositionGetInteger,(POSITION_TIME)用途： ポジションの約定時刻を取得し、現在時刻との差分で**TimeStop（時間切れ決済）**を判定する。
SymbolInfoDouble,(SYMBOL_TRADE_TICK_VALUE) / (SYMBOL_ASK/BID)用途： リスク％計算（1ロットあたりの変動価値）および、現在価格の取得。
SymbolInfoInteger,(SYMBOL_TRADE_STOPS_LEVEL)用途： StopLevelの取得。注文やSL修正時にブローカーの禁止帯（近すぎる価格）を避けるために必須。
trade.BuyStoptrade.SellStop,"bool BuyStop(vol, price, symbol, sl, tp, type_time, expiration, ...)用途： エントリー用。仕様にある「PendingOrderはTTL_short=14本」を実現するため、引数 expiration に時間をセットする。"
trade.PositionClose,"bool PositionClose(ticket, volume)用途： **MiniTP（部分利確）**の実装に使用。volume に全体の30%などを指定して部分決済を行う。"
trade.PositionModify,"bool PositionModify(ticket, sl, tp)用途： **BE（建値移動）**の実装に使用。条件を満たしたときにSLをエントリー価格へ移動させる。"
PrintFormat,"PrintFormat(""Trigger: %s, R-Dist: %.2f"", ...)用途： エントリー理由やガード理由を整形してログ出力する。"
StringFormat,"string StringFormat(...)用途： 注文時のコメント生成（例: ""ChannelBreak_TP1""）などに使用。"
OnInit,int OnInit(),プログラムの初期化時（チャート適用時）に一度だけ実行される。初期設定やインジケーターハンドルの作成に使用。
OnDeinit,void OnDeinit(const int reason),プログラムの終了時（削除時）に一度だけ実行される。オブジェクトの削除やメモリ開放に使用。
OnTick,void OnTick(),新しいティック（価格変動）が来るたびに実行される。EAのメインロジックはここに記述する。
OnCalculate,int OnCalculate(...),インジケーター専用。価格更新時に計算を行うためのメイン関数。引数のパターンが2種類ある。
OnTimer,void OnTimer(),EventSetTimerで設定した時間間隔ごとに実行される。
OnTrade,void OnTrade(),取引履歴（注文、約定、ポジション）に変化があった時に実行される。
OnChartEvent,"void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)",クリック、キー入力、オブジェクト作成などのチャートイベントが発生した時に実行される。
SymbolInfoDouble,"double SymbolInfoDouble(string name, ENUM_SYMBOL_INFO_DOUBLE prop_id)","指定銘柄の価格情報（SYMBOL_ASK, SYMBOL_BID, SYMBOL_POINTなど）を取得。"
SymbolInfoInteger,"long SymbolInfoInteger(string name, ENUM_SYMBOL_INFO_INTEGER prop_id)","指定銘柄の整数情報（SYMBOL_SPREAD, SYMBOL_DIGITSなど）を取得。"
SymbolInfoString,"string SymbolInfoString(string name, ENUM_SYMBOL_INFO_STRING prop_id)","指定銘柄の文字列情報（SYMBOL_DESCRIPTION, SYMBOL_CURRENCY_BASEなど）を取得。"
CopyRates,"int CopyRates(string symbol_name, ENUM_TIMEFRAMES timeframe, int start_pos, int count, MqlRates& rates_array[])",ローソク足データ（OHLC、時間、出来高）をMqlRates構造体配列にコピーする。
iClose,"double iClose(string symbol, ENUM_TIMEFRAMES timeframe, int shift)",指定した足の「終値」を取得。
iOpen,"double iOpen(string symbol, ENUM_TIMEFRAMES timeframe, int shift)",指定した足の「始値」を取得。
iHigh,"double iHigh(string symbol, ENUM_TIMEFRAMES timeframe, int shift)",指定した足の「高値」を取得。
iLow,"double iLow(string symbol, ENUM_TIMEFRAMES timeframe, int shift)",指定した足の「安値」を取得。
iTime,"datetime iTime(string symbol, ENUM_TIMEFRAMES timeframe, int shift)",指定した足の「開始時刻」を取得。
iVolume,"long iVolume(string symbol, ENUM_TIMEFRAMES timeframe, int shift)",指定した足の「ティック出来高」を取得。
iMA,"int iMA(string symbol, ENUM_TIMEFRAMES period, int ma_period, int ma_shift, ENUM_MA_METHOD ma_method, ENUM_APPLIED_PRICE applied_price)",移動平均線のハンドルを作成。
iRSI,"int iRSI(string symbol, ENUM_TIMEFRAMES period, int ma_period, ENUM_APPLIED_PRICE applied_price)",RSIのハンドルを作成。
iMACD,"int iMACD(string symbol, ENUM_TIMEFRAMES period, int fast_ema, int slow_ema, int signal, ENUM_APPLIED_PRICE applied_price)",MACDのハンドルを作成。
iBands,"int iBands(string symbol, ENUM_TIMEFRAMES period, int bands_period, int bands_shift, double deviation, ENUM_APPLIED_PRICE applied_price)",ボリンジャーバンドのハンドルを作成。
iATR,"int iATR(string symbol, ENUM_TIMEFRAMES period, int ma_period)",ATR（ボラティリティ）のハンドルを作成。
CopyBuffer,"int CopyBuffer(int indicator_handle, int buffer_num, int start_pos, int count, double& buffer[])",作成したハンドルの計算結果を配列にコピーして取得する。
IndicatorRelease,bool IndicatorRelease(int indicator_handle),不要になったインジケーターハンドルを開放する（メモリ節約）。
PositionsTotal,int PositionsTotal(),現在保有中のポジション数を返す。
PositionSelect,bool PositionSelect(string symbol),通貨ペア名を指定してポジションを選択する（EAが1銘柄専用の場合に便利）。
PositionSelectByTicket,bool PositionSelectByTicket(ulong ticket),チケット番号を指定してポジションを選択する（複数銘柄や複数ポジション管理に必須）。
PositionGetDouble,double PositionGetDouble(ENUM_POSITION_PROPERTY_DOUBLE property_id),"選択中ポジションの価格情報（POSITION_PRICE_OPEN, POSITION_SL, POSITION_TP, POSITION_PROFIT）を取得。"
PositionGetInteger,long PositionGetInteger(ENUM_POSITION_PROPERTY_INTEGER property_id),"選択中ポジションの整数情報（POSITION_TICKET, POSITION_MAGIC, POSITION_TYPE）を取得。"
HistorySelect,"bool HistorySelect(datetime from_date, datetime to_date)",指定期間の取引履歴をキャッシュにロードする。
HistoryDealsTotal,int HistoryDealsTotal(),HistorySelectでロードされた約定履歴の総数を返す。
HistoryDealGetTicket,ulong HistoryDealGetTicket(int index),インデックスを指定して約定履歴のチケット番号を取得する。
OrderSend,"bool OrderSend(MqlTradeRequest& request, MqlTradeResult& result)",注文をサーバーに送信する（ネイティブ関数）。
OrderCalcMargin,"bool OrderCalcMargin(ENUM_ORDER_TYPE action, string symbol, double volume, double price, double& margin)",必要証拠金を計算する。
AccountInfoDouble,double AccountInfoDouble(ENUM_ACCOUNT_INFO_DOUBLE property_id),"口座の資金情報（ACCOUNT_BALANCE, ACCOUNT_EQUITY, ACCOUNT_MARGIN_FREE）を取得。"
AccountInfoInteger,long AccountInfoInteger(ENUM_ACCOUNT_INFO_INTEGER property_id),"口座設定（ACCOUNT_LEVERAGE, ACCOUNT_LOGIN, ACCOUNT_LIMIT_ORDERS）を取得。"
AccountInfoString,string AccountInfoString(ENUM_ACCOUNT_INFO_STRING property_id),口座名義、ブローカー名、通貨名（ACCOUNT_CURRENCY）などを取得。
TerminalInfoInteger,long TerminalInfoInteger(ENUM_TERMINAL_INFO_INTEGER property_id),MT5端末の状態（TERMINAL_CONNECTEDなど）を取得。
ChartID,long ChartID(),現在実行中のチャートIDを取得。
ChartPeriod,ENUM_TIMEFRAMES ChartPeriod(long chart_id=0),チャートの時間足を返す（_Period変数と同じ）。
ChartSymbol,string ChartSymbol(long chart_id=0),チャートの銘柄名を返す（_Symbol変数と同じ）。
ObjectCreate,"bool ObjectCreate(long chart_id, string name, ENUM_OBJECT type, int sub_window, datetime time1, double price1, ...)",オブジェクト（ライン、ラベル、ボタン等）を作成する。
ObjectDelete,"bool ObjectDelete(long chart_id, string name)",指定した名前のオブジェクトを削除する。
ObjectSetInteger,"bool ObjectSetInteger(long chart_id, string name, ENUM_OBJECT_PROPERTY_INTEGER prop_id, long value)",オブジェクトの色、幅、スタイルなどを設定。
ObjectSetDouble,"bool ObjectSetDouble(long chart_id, string name, ENUM_OBJECT_PROPERTY_DOUBLE prop_id, double value)",オブジェクトの価格座標などを設定。
ObjectSetString,"bool ObjectSetString(long chart_id, string name, ENUM_OBJECT_PROPERTY_STRING prop_id, string value)",オブジェクトのテキスト内容や説明を設定。
Comment,"void Comment(argument, ...)",チャート左上にテキストを表示。
ArrayResize,"int ArrayResize(void& array[], int new_size, int reserve_size=0)",動的配列のサイズを変更する。
ArraySetAsSeries,"bool ArraySetAsSeries(void& array[], bool flag)",配列のインデックス方向を時系列（0が最新）に設定する。
ArrayInitialize,"int ArrayInitialize(void& array[], double value)",配列の全要素を指定した値で初期化する。
ArrayMaximum,"int ArrayMaximum(const void& array[], int start=0, int count=WHOLE_ARRAY)",配列内の最大値を持つインデックスを返す。
ArrayMinimum,"int ArrayMinimum(const void& array[], int start=0, int count=WHOLE_ARRAY)",配列内の最小値を持つインデックスを返す。
NormalizeDouble,"double NormalizeDouble(double value, int digits)",小数点以下の桁数を指定して丸める。価格の比較や注文時に必須。
DoubleToString,"string DoubleToString(double value, int digits=8)",数値を文字列に変換する（ログ出力や表示用）。
StringToDouble,double StringToDouble(string value),文字列を数値に変換する（インプットパラメータの処理など）。
MathAbs,double MathAbs(double value),絶対値を返す。
MathMax,"double MathMax(double value1, double value2)",2つの値のうち大きい方を返す。
MathMin,"double MathMin(double value1, double value2)",2つの値のうち小さい方を返す。
MathRand,int MathRand(),0〜32767の乱数を生成する。
TimeCurrent,datetime TimeCurrent(),サーバーの現在時刻（最新のティック時刻）を取得。
TimeLocal,datetime TimeLocal(),パソコン（ローカル）の現在時刻を取得。
TimeToString,"string TimeToString(datetime value, int mode=TIME_DATE|TIME_MINUTES)",時刻型データを文字列に変換する。
StringToTime,datetime StringToTime(const string value),"""yyyy.mm.dd hh:mi"" 形式の文字列を時刻型に変換する。"
Print,"void Print(argument, ...)",ツールボックスの「エキスパート」タブにログを出力する。
PrintFormat,"void PrintFormat(string format_string, ...)","C言語のprintfのように、フォーマット指定子（%d, %f, %s）を使ってログを出力する。"
Alert,"void Alert(argument, ...)",ポップアップアラートを表示し、音を鳴らす。
GetLastError,int GetLastError(),直近に発生したエラーコードを取得する。エラー原因の特定に使用。
ResetLastError,void ResetLastError(),エラーコード変数 _LastError を0にリセットする。
Buy,"bool Buy(double volume, string symbol=NULL, double price=0.0, double sl=0.0, double tp=0.0, string comment="""")",成行買い注文。
Sell,"bool Sell(double volume, string symbol=NULL, double price=0.0, double sl=0.0, double tp=0.0, string comment="""")",成行売り注文。
BuyLimit,"bool BuyLimit(double volume, double price, string symbol=NULL, double sl=0.0, double tp=0.0, ...)",指値買い（Buy Limit）注文。
SellLimit,"bool SellLimit(double volume, double price, string symbol=NULL, double sl=0.0, double tp=0.0, ...)",指値売り（Sell Limit）注文。
BuyStop,"bool BuyStop(double volume, double price, string symbol=NULL, double sl=0.0, double tp=0.0, ...)",逆指値買い（Buy Stop）注文。
SellStop,"bool SellStop(double volume, double price, string symbol=NULL, double sl=0.0, double tp=0.0, ...)",逆指値売り（Sell Stop）注文。
PositionClose,"bool PositionClose(ulong ticket, ulong deviation=ULONG_MAX)",指定したチケット番号のポジションを決済。
PositionCloseAll,bool PositionCloseAll(),（ヘッジ口座用）保有ポジションを全て決済する便利なメソッド。
PositionModify,"bool PositionModify(ulong ticket, double sl, double tp)",ポジションのSL/TP（損切り/利確）を変更する。
SetExpertMagicNumber,void SetExpertMagicNumber(ulong magic),注文時に付与するマジックナンバーを一括設定する。