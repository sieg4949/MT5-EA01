# -*- coding: utf-8 -*-
"""
USDJPY M5 CSV を対象にしたミニマム戦略シミュレータ（参照用）
-------------------------------------------------------------
■今回の版（B優先：STRUCT > BURST > EDGE）
  - STRUCTの条件を「反対側の2段（LL→LL / HH→HH）」のみに緩和
    * 例：BUY保有中は LL→LL が出たら即EXIT（HHストップ条件は削除）
  - MaxBars（時間切れEXIT）は削除
  - BURSTはRSI(3)の差分を使用（|ΔRSI|>=14）だが、優先順位はSTRUCTの後
  - 入口は据え置き（Edge_Entry_Min=0.60）でシグナル母数を維持
  - HeatmapはA+B+D（スイング・前日高安/当日始値・日VWAP/H1累積VWAP）
  - H1更新時のみHeatmap再構築（高速化）

■入出力
  - 入力CSV：UTF-16, ヘッダ無し, 列[time, open, high, low, close, volume, spread_points]
  - 例：python simulator_b_relaxed.py /path/to/USDJPYM5.csv
  - 本ファイル単体でも実行可能（末尾の __main__ 参照）。

■注意
  - 参考実装のため、約定＆決済は「確定足ベース」で簡略化している
  - スプレッドは CSV の spread_points を 0.001 で金額化して R に反映

"""

import sys
from dataclasses import dataclass
from typing import Tuple, Dict, Any

import numpy as np
import pandas as pd


# ========= ユーティリティ：テクニカル計算 =========

def atr(df: pd.DataFrame, n: int) -> pd.Series:
    """ATR（指数平滑版）を計算する。"""
    h, l, c = df["high"], df["low"], df["close"]
    pc = c.shift(1)
    tr = pd.concat([h - l, (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False, min_periods=n).mean()


def resample_bars(df_m5: pd.DataFrame, tf: str) -> pd.DataFrame:
    """任意のタイムフレームにリサンプリング（OHLCV）。"""
    o = df_m5["open"].resample(tf).first()
    h = df_m5["high"].resample(tf).max()
    l = df_m5["low"].resample(tf).min()
    c = df_m5["close"].resample(tf).last()
    v = df_m5["volume"].resample(tf).sum()
    return pd.DataFrame({"open": o, "high": h, "low": l, "close": c, "volume": v}).dropna()


def detect_pivots(h: pd.Series, l: pd.Series, k: int) -> Tuple[pd.Series, pd.Series]:
    """左右k本の極値でピボット（高値/安値）を検出。Trueのインデックスがピボット位置。"""
    n = len(h)
    ph = np.zeros(n, bool)
    pl = np.zeros(n, bool)
    hv, lv = h.values, l.values
    for i in range(k, n - k):
        if hv[i] == hv[i - k:i + k + 1].max():
            ph[i] = True
        if lv[i] == lv[i - k:i + k + 1].min():
            pl[i] = True
    return pd.Series(ph, h.index), pd.Series(pl, l.index)


def ema(series: pd.Series, n: int):
    """EMA（指数移動平均）。"""
    return series.ewm(alpha=2 / (n + 1), adjust=False).mean()


def rsi(series: pd.Series, n: int = 3):
    """RSI（指数平滑）。n=3の短期RSIを想定。"""
    delta = series.diff()
    up = delta.clip(lower=0)
    down = -delta.clip(upper=0)
    ma_up = up.ewm(alpha=1 / n, adjust=False, min_periods=n).mean()
    ma_down = down.ewm(alpha=1 / n, adjust=False, min_periods=n).mean()
    rs = ma_up / ma_down.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))
    return rsi.fillna(50.0)


# ========= Heatmap（A+B+D） =========

@dataclass
class HMConfig:
    """ヒートマップの設定。"""
    bucket_pips: float = 2.0
    swing_k: int = 3
    lookback_m5: int = 120
    weights: Dict[str, float] = None

    def __post_init__(self):
        if self.weights is None:
            # A: スイング極値, B: 前日高安/当日始値, D: 日VWAP & H1累積VWAP
            self.weights = {"A": 30, "B": 20, "D": 50}


def typical_price(df: pd.DataFrame) -> pd.Series:
    """典型価格（H+L+C)/3。"""
    return (df["high"] + df["low"] + df["close"]) / 3.0


def vwap_series(df: pd.DataFrame) -> pd.Series:
    """日内VWAP（日区切りでの累積）。"""
    tp = typical_price(df)
    vol = df["volume"].replace(0, 1.0)
    day = df.index.floor("1D")
    cum_pv = (tp * vol).groupby(day).cumsum()
    cum_v = (vol).groupby(day).cumsum()
    return cum_pv / cum_v


def vwap_h1_series(h1: pd.DataFrame) -> pd.Series:
    """H1の累積VWAP（全区間累積）。"""
    tp = typical_price(h1)
    vol = h1["volume"].replace(0, 1.0)
    return (tp * vol).cumsum() / vol.cumsum()


def build_heatmap(df_m5: pd.DataFrame, h1: pd.DataFrame, ref_idx: int, cfg: HMConfig, pip: float):
    """
    直近lookback_m5本の価格帯にバケットを作り、A+B+Dのスコアで各帯の強さを数値化。
    H1更新時のみ再構築する前提で使用（高速化）。
    """
    i0 = max(0, ref_idx - cfg.lookback_m5)
    w = df_m5.iloc[i0:ref_idx]
    if len(w) < 60:
        return {"buckets": np.array([]), "scores": np.array([])}

    lo = float(w["low"].min())
    hi = float(w["high"].max())
    rng = hi - lo
    if rng <= 0:
        return {"buckets": np.array([]), "scores": np.array([])}

    bucket = pip * cfg.bucket_pips
    n = int(np.ceil(rng / bucket)) + 1
    buckets = lo + np.arange(n) * bucket

    score_A = np.zeros(n)
    score_B = np.zeros(n)
    score_D = np.zeros(n)

    # A: スイング極値の投票
    pivH, pivL = detect_pivots(w["high"], w["low"], cfg.swing_k)
    swings = list(w["high"][pivH].values) + list(w["low"][pivL].values)
    for px in swings:
        idx = int(np.clip(np.floor((px - lo) / bucket), 0, n - 1))
        score_A[idx] += 1.0

    # B: 前日高安と当日始値
    d1 = resample_bars(df_m5.loc[:w.index[-1]], "1D")
    if len(d1) >= 2:
        prev = d1.iloc[-2]
        curr = d1.iloc[-1]
        for lv in [prev["high"], prev["low"], curr["open"]]:
            if np.isnan(lv):
                continue
            idx = int(np.clip(np.floor((lv - lo) / bucket), 0, n - 1))
            score_B[idx] += 1.0

    # D: 日内VWAP と H1累積VWAP（直近値）
    vwap_d = vwap_series(df_m5.loc[:w.index[-1]])
    h1_local = h1.loc[:w.index[-1].floor("1H")]
    vwap_h1 = vwap_h1_series(h1_local) if len(h1_local) > 0 else pd.Series(dtype=float)
    lv_list = []
    if len(vwap_d) > 0 and not np.isnan(vwap_d.iloc[-1]):
        lv_list.append(float(vwap_d.iloc[-1]))
    if len(vwap_h1) > 0 and not np.isnan(vwap_h1.iloc[-1]):
        lv_list.append(float(vwap_h1.iloc[-1]))
    for lv in lv_list:
        idx = int(np.clip(np.floor((lv - lo) / bucket), 0, n - 1))
        score_D[idx] += 1.0

    # 正規化して 0-100 スコア化
    wA, wB, wD = cfg.weights["A"], cfg.weights["B"], cfg.weights["D"]
    raw = wA * score_A + wB * score_B + wD * score_D
    maxv = raw.max() if raw.max() > 0 else 1.0
    scores = (raw / maxv) * 100.0
    return {"buckets": buckets, "scores": scores}


def extract_near_zone(buckets, scores, price_now):
    """最もスコアが高く、かつ現在値に近い帯を返す（最大16候補を探索）。"""
    if len(buckets) == 0:
        return None
    idx_sorted = np.argsort(scores)[::-1][:16]
    best = None
    for idx in idx_sorted:
        level = float(buckets[idx])
        sc = float(scores[idx])
        cand = (level, sc, "A/B/D")
        if best is None:
            best = cand
            continue
        closer = abs(level - price_now) < abs(best[0] - price_now)
        same_and_higher = (abs(level - price_now) == abs(best[0] - price_now)) and (sc > best[1])
        if closer or same_and_higher:
            best = cand
    return best


def h1_regime(h1: pd.DataFrame, idx: int):
    """H1の回帰傾きで TRD（トレンド）/ RNG（レンジ）を判定。"""
    if idx < 50:
        return "RNG", 0.0
    span = 48
    y = h1["close"].iloc[idx - span:idx].values
    x = np.arange(len(y))
    x_mean = x.mean()
    y_mean = y.mean()
    beta = ((x - x_mean) * (y - y_mean)).sum() / max(1e-9, ((x - x_mean) ** 2).sum())
    thr = np.std(y) * 0.002
    return ("TRD", beta) if abs(beta) >= thr else ("RNG", beta)


# ========= メイン：B優先（STRUCT緩和／時間切れなし） =========

def simulate_B_exit_relaxed(csv_df: pd.DataFrame):
    """
    B優先（STRUCT > BURST > EDGE）で、STRUCTは「反対側2段（LL→LL or HH→HH）のみ」。
    MaxBars（時間切れEXIT）は削除。入口は Edge_Entry_Min=0.60 のまま。
    """
    # ---- パラメータ（入りは据え置き） ----
    HM = HMConfig()
    EnterTol_H1ATR = 0.45
    ExitTol_H1ATR = 0.65
    HM_Score_Th = 58.0
    SwingLB = 6
    EntryBuf_ATR = 0.12
    pip_size = 0.01
    MA_M5_Period = 20
    Edge_Exit_Thresh = 0.30
    Edge_Entry_Min = 0.60
    BurstDelta = 14.0  # |ΔRSI3| >= 14

    df = csv_df.copy()
    m5_atr = atr(df, 14)
    h1 = resample_bars(df, "1H")
    h1_atr = atr(h1, 14)

    # ---- 事前計算（ベクトル化で高速化） ----
    ema20 = ema(df["close"], MA_M5_Period)
    slope_norm = (((ema20 - ema20.shift(3)) / (3 * m5_atr)).clip(-1, 1) + 1) / 2.0
    pos_norm = (((df["close"] - ema20) / (2 * m5_atr)).clip(-1, 1) + 1) / 2.0
    rsi3 = rsi(df["close"], 3)
    rsi3_norm = (rsi3 / 100.0).clip(0, 1)
    rsi3_diff = rsi3.diff()

    def edge_at(i: int, side: str):
        """エッジ指標（0-1）。位置・傾き・RSI・構造の合成。"""
        hh = int(df["high"].iloc[i - 1] > df["high"].iloc[i - 3:i - 1].max())
        ll = int(df["low"].iloc[i - 1] < df["low"].iloc[i - 3:i - 1].min())
        struct_up = 1.0 if (hh and not ll) else (0.5 if (hh and ll) else 0.0)
        struct_dn = 1.0 if (ll and not hh) else (0.5 if (hh and ll) else 0.0)
        if side == "LONG":
            comps = [pos_norm.iloc[i - 1], slope_norm.iloc[i - 1], rsi3_norm.iloc[i - 1], struct_up]
            w = [0.35, 0.25, 0.25, 0.15]
        else:
            comps = [1 - pos_norm.iloc[i - 1], 1 - slope_norm.iloc[i - 1], 1 - rsi3_norm.iloc[i - 1], struct_dn]
            w = [0.35, 0.25, 0.25, 0.15]
        comps = [c if np.isfinite(c) else 0.5 for c in comps]
        return float(np.dot(comps, w))

    def burst(side: str, i: int):
        """逆向きBurst：3連続LL/HH + RSI(3)差分の急転（|Δ|>=14）。"""
        if side == "LONG":
            cond_ll = (df["low"].iloc[i - 1] < df["low"].iloc[i - 2]) and (df["low"].iloc[i - 2] < df["low"].iloc[i - 3])
            cond_rsi = (rsi3_diff.iloc[i - 1] <= -BurstDelta)
            return bool(cond_ll and cond_rsi)
        else:
            cond_hh = (df["high"].iloc[i - 1] > df["high"].iloc[i - 2]) and (df["high"].iloc[i - 2] > df["high"].iloc[i - 3])
            cond_rsi = (rsi3_diff.iloc[i - 1] >= BurstDelta)
            return bool(cond_hh and cond_rsi)

    def structure_shift_relaxed(side: str, i: int):
        """構造崩壊（緩和版）：反対側LL→LL / HH→HH のみで即EXIT。"""
        if side == "LONG":
            return bool((df["low"].iloc[i - 1] < df["low"].iloc[i - 2]) and (df["low"].iloc[i - 2] < df["low"].iloc[i - 3]))
        else:
            return bool((df["high"].iloc[i - 1] > df["high"].iloc[i - 2]) and (df["high"].iloc[i - 2] > df["high"].iloc[i - 3]))

    def insurance_sl(side: str, entry_ts, entry_price: float):
        """
        保険SL：H1スイングの遠目側 + 0.2×ATR(H1)
        * 約定時に1回だけ計算（高速化）
        """
        h1_cut = h1.loc[:entry_ts.floor("1H")]
        if len(h1_cut) < 10:
            return np.nan
        ph, pl = detect_pivots(h1_cut["high"], h1_cut["low"], 3)
        sh = h1_cut["high"][ph]
        sl = h1_cut["low"][pl]
        a_h1 = h1_atr.loc[:entry_ts.floor("1H")].iloc[-1] if entry_ts.floor("1H") in h1_atr.index else np.nan
        if np.isnan(a_h1):
            a_h1 = float(h1_atr.dropna().iloc[-1]) if len(h1_atr.dropna()) > 0 else 0.2
        if side == "LONG":
            cands = sl[sl < entry_price].tail(5).values
            base = (entry_price - 2.5 * a_h1) if len(cands) == 0 else cands[-1]
            return float(base - 0.20 * a_h1)
        else:
            cands = sh[sh > entry_price].tail(5).values
            base = (entry_price + 2.5 * a_h1) if len(cands) == 0 else cands[-1]
            return float(base + 0.20 * a_h1)

    # ---- メインループ ----
    window_open = False
    ttl = 24
    cool = 0
    side = None
    zone_lvl = None

    pending = []   # 逆指値候補（発注準備）
    pos = None     # 建玉
    trades = []    # 約定結果

    last_edge = None    # ヒステリシス用の前回Edge

    last_h1_ts = None
    hm_cache = None
    times = df.index

    for i in range(80, len(df)):
        ts = times[i]
        price_prev = df["close"].iloc[i - 1]
        h1_ts = ts.floor("1H")

        # H1更新時のみヒートマップ再構築
        if (last_h1_ts is None) or (h1_ts != last_h1_ts):
            last_h1_ts = h1_ts
            hm_cache = build_heatmap(df, h1, i - 1, HM, pip_size)
            near = extract_near_zone(hm_cache["buckets"], hm_cache["scores"], price_prev) if len(hm_cache["buckets"]) > 0 else None
        else:
            near = None

        # レジーム判定（回帰傾き）
        h1_idx = h1.index.get_loc(h1_ts) if h1_ts in h1.index else None
        regime, _ = ("RNG", 0.0) if (h1_idx is None) else h1_regime(h1, h1_idx)
        a_h1 = h1_atr.iloc[h1_idx - 1] if (h1_idx is not None and h1_idx >= 2) else np.nan
        a_m5 = m5_atr.iloc[i - 1]

        # 窓のOPEN/CLOSE管理
        if near is not None and not np.isnan(a_h1):
            lvl, sc, _ = near
            if (not window_open) and (abs(price_prev - lvl) <= EnterTol_H1ATR * a_h1) and (sc >= HM_Score_Th) and cool <= 0:
                window_open = True
                ttl = 24
                side = ("UP" if lvl >= price_prev else "DOWN")
                zone_lvl = lvl
        if window_open:
            ttl -= 1
            if ttl <= 0 or (not np.isnan(a_h1) and abs(price_prev - zone_lvl) >= ExitTol_H1ATR * a_h1):
                window_open = False
                cool = 5
                side = None
                zone_lvl = None
        if cool > 0:
            cool -= 1

        # 入口生成（TRD=ブレイクアウト / RNG=リバース）
        if window_open and (pos is None):
            seg = df.iloc[i - SwingLB:i]
            if regime == "TRD":
                if side == "UP":
                    entry = float(seg["high"].max()) + EntryBuf_ATR * a_m5
                    if edge_at(i, "LONG") >= Edge_Entry_Min:
                        pending.append(("BUY", entry, ts, regime, "BO"))
                        window_open = False
                        cool = 5
                else:
                    entry = float(seg["low"].min()) - EntryBuf_ATR * a_m5
                    if edge_at(i, "SHORT") >= Edge_Entry_Min:
                        pending.append(("SELL", entry, ts, regime, "BO"))
                        window_open = False
                        cool = 5
            else:
                if side == "UP":
                    entry = float(seg["low"].min()) - 0.10 * a_m5
                    if edge_at(i, "SHORT") >= Edge_Entry_Min:
                        pending.append(("SELL", entry, ts, regime, "RV"))
                        window_open = False
                        cool = 5
                else:
                    entry = float(seg["high"].max()) + 0.10 * a_m5
                    if edge_at(i, "LONG") >= Edge_Entry_Min:
                        pending.append(("BUY", entry, ts, regime, "RV"))
                        window_open = False
                        cool = 5

        # 約定と保険SL設定
        if (pos is None) and pending:
            hi, lo = df["high"].iloc[i], df["low"].iloc[i]
            spr_points = float(df["spread_points"].iloc[i]) if "spread_points" in df.columns else 0.0
            spread_price = spr_points * 0.001  # ポイント→価格の簡易換算
            keep = []
            for side_p, entry, ots, regime_p, kind in pending:
                ok = (side_p == "BUY" and hi >= entry) or (side_p == "SELL" and lo <= entry)
                if ok:
                    sl_price = insurance_sl("LONG" if side_p == "BUY" else "SHORT", ots, entry)
                    if np.isnan(sl_price):
                        # フォールバック：ATRベース
                        sl_price = entry - 1.5 * a_m5 if side_p == "BUY" else entry + 1.5 * a_m5
                    r_unit = abs(entry - sl_price)
                    pos = {
                        "side": "LONG" if side_p == "BUY" else "SHORT",
                        "entry": entry,
                        "sl": sl_price,
                        "r_unit": r_unit,
                        "opened_idx": i,
                        "opened_ts": ots,
                        "regime": regime_p,
                        "kind": kind,
                        "spread_R": spread_price / max(1e-9, r_unit),
                    }
                    last_edge = None
                else:
                    keep.append((side_p, entry, ots, regime_p, kind))
            pending = keep

        # ポジション管理（STRUCT > BURST > EDGE）※時間切れEXITなし
        if pos is not None:
            reason = None
            exitp = None
            price = df["close"].iloc[i]
            side_now = pos["side"]

            # 1) 構造崩壊（最優先）
            if structure_shift_relaxed(side_now, i):
                reason = "STRUCT"
                exitp = price
            # 2) 逆向きBurst
            elif burst(side_now, i):
                reason = "BURST"
                exitp = price
            # 3) Edgeヒステリシス（2本連続で下回る）
            else:
                e_now = edge_at(i, "LONG" if side_now == "LONG" else "SHORT")
                if last_edge is None:
                    last_edge = e_now
                else:
                    if (e_now < Edge_Exit_Thresh) and (last_edge < Edge_Exit_Thresh):
                        reason = "EDGE"
                        exitp = price
                    last_edge = e_now

            # 4) 保険SLヒット
            hi, lo = df["high"].iloc[i], df["low"].iloc[i]
            if reason is None:
                if side_now == "LONG" and lo <= pos["sl"]:
                    reason = "SL"
                    exitp = pos["sl"]
                if side_now == "SHORT" and hi >= pos["sl"]:
                    reason = "SL"
                    exitp = pos["sl"]

            if reason is not None:
                rr = ((exitp - pos["entry"]) / pos["r_unit"]) if side_now == "LONG" else ((pos["entry"] - exitp) / pos["r_unit"])
                rr -= pos["spread_R"]
                trades.append({
                    "side": side_now,
                    "entry": pos["entry"],
                    "exit": exitp,
                    "r_result": rr,
                    "opened_ts": pos["opened_ts"],
                    "closed_ts": times[i],
                    "reason": reason,
                    "regime": pos["regime"],
                    "kind": pos["kind"],
                })
                pos = None
                last_edge = None

    # ---- 集計 ----
    tr_df = pd.DataFrame(trades) if trades else pd.DataFrame(
        columns=["side", "entry", "exit", "r_result", "opened_ts", "closed_ts", "reason", "regime", "kind"]
    )
    total = len(trades)
    wins = sum(1 for t in trades if t["r_result"] > 0)
    win_rate = (wins / total * 100.0) if total > 0 else 0.0
    total_r = sum(t["r_result"] for t in trades)
    avg_r = (total_r / total) if total > 0 else 0.0
    eq = 0.0
    peak = 0.0
    maxdd = 0.0
    for t in trades:
        eq += t["r_result"]
        peak = max(peak, eq)
        maxdd = max(maxdd, peak - eq)
    r = pd.Series([t["r_result"] for t in trades])
    gw = r[r > 0].sum()
    gl = -r[r < 0].sum()
    pf = float(gw / gl) if gl > 0 else float("inf")
    summary = {
        "total_trades": total,
        "win_rate%": round(win_rate, 2),
        "total_R": round(total_r, 2),
        "avg_R": round(avg_r, 3),
        "maxDD_R": round(maxdd, 2),
        "PF": round(pf, 2) if np.isfinite(pf) else "inf",
        "reasons": tr_df["reason"].value_counts().to_dict() if total > 0 else {},
    }
    return tr_df, summary


# ========= CLI実行部（例：末尾6,000本で実行） =========
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python simulator_b_relaxed.py /path/to/USDJPYM5.csv")
        sys.exit(1)

    csv_path = sys.argv[1]
    # CSVは UTF-16 / ヘッダ無し を想定
    df = pd.read_csv(csv_path, encoding="utf-16", header=None,
                     names=["time", "open", "high", "low", "close", "volume", "spread_points"])
    df["time"] = pd.to_datetime(df["time"], errors="coerce")
    for c in ["open", "high", "low", "close", "volume", "spread_points"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["time", "open", "high", "low", "close"]).sort_values("time").set_index("time")

    # 末尾6,000本で実行（検証区間は必要に応じて調整）
    df_small = df.tail(6000).copy()
    tr_df, summary = simulate_B_exit_relaxed(df_small)

    print("【B優先（STRUCT=反対側2段のみ / MaxBars削除）| ΔRSI14】実行結果")
    for k, v in summary.items():
        print(f"- {k}: {v}")

    # 取引プレビュー（先頭/末尾10件）
    if len(tr_df) > 0:
        preview = pd.concat([tr_df.head(10), tr_df.tail(10)]).reset_index(drop=True)
        print("\\n[Preview]")
        print(preview.to_string(index=False))
