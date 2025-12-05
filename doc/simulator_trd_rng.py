# -*- coding: utf-8 -*-
"""
================================================================================
USDJPY 1分CSV用 マルチタイム・シミュレーター（TRDブレイク専用 / 研究用）
================================================================================
■ 目的
- しぐれさんとの検証で使った Python シミュレーターを、1ファイルに集約。
- M1 → M5/H1 へリサンプルし、H1でレジーム（TRD/RNG）を判定。
- TRD局面のみで「ブレイクアウト＋Edge品質フィルタ」の発注、
  出口は STRUCT → BURST → EDGE → SL → END の優先順位。
- ATRキャップ（例：3.0×ATR(H1)）や、ヒステリシス付きゲートをオン/オフ可能。

■ 前提
- 入力CSVの1行目例：
  2025.08.28 01:45,147.20400,147.21200,147.20000,147.20700,16,0
  （time, open, high, low, close, tickvol, spread_or_zero）
- 通貨は USDJPY 想定。pipsは「0.01」を1pipsとして扱います。

■ 使い方（例）
1) ハイブリッド出口ロジック（STRUCT=3, BURST=16, EDGE=0.28×3本）で実行
   python simulator_trd_rng.py --csv /mnt/data/USDJPYM1.csv --run hybrid \
          --entry_buffer 0.10 --edge_entry 0.60 --sl_extra 0.12 \
          --edge_exit_thr 0.28 --edge_exit_consec 3 --burst_delta 16 \
          --atr_cap 3.0

2) ATRキャップの少回数ステップ比較（2.0 / 3.0 / 4.0）
   python simulator_trd_rng.py --csv /mnt/data/USDJPYM1.csv --run atr_sweep \
          --caps 2.0 3.0 4.0

3) ヒステリシス付きゲートの比較（従来 vs ヒステリシス）
   python simulator_trd_rng.py --csv /mnt/data/USDJPYM1.csv --run gate \
          --enter_coef 0.0022 --exit_coef 0.0018 --atr_cap 3.0

■ 出力
- 画面にサマリ（pandas.DataFrame）を表示（Notebookの場合）。
- Excelを /mnt/data 配下に保存（ファイル名は run に応じて自動）。

※ このスクリプトは研究用であり、実運用の成績を保証するものではありません。
"""

import argparse
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd


# ============================================================
# ユーティリティ（共通）
# ============================================================

PIP = 0.01  # USDJPY想定。0.01を1pipsとして定義


def pips(v: float) -> float:
    """価格差をpipsに変換するヘルパー。"""
    return v / PIP


def read_m1_csv(path: str) -> pd.DataFrame:
    """
    M1 CSVを読み込む。想定カラム：
    time, open, high, low, close, tickvol, spread_or_zero
    """
    encodings_try = ["utf-16", "utf-8-sig", "cp932"]
    df = None
    for enc in encodings_try:
        try:
            df = pd.read_csv(
                path,
                encoding=enc,
                header=None,
                names=[
                    "time",
                    "open",
                    "high",
                    "low",
                    "close",
                    "tickvol",
                    "spread_or_zero",
                ],
            )
            break
        except Exception:
            continue

    if df is None:
        raise RuntimeError("CSVの読み込みに失敗しました。エンコーディングを確認してください。")

    # 時刻をIndex化し、数値に整形
    df["time"] = pd.to_datetime(df["time"], format="%Y.%m.%d %H:%M", errors="coerce")
    df = df.dropna(subset=["time"]).set_index("time").sort_index()
    for c in ["open", "high", "low", "close", "tickvol", "spread_or_zero"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna()
    return df


def resample_ohlc(src: pd.DataFrame, rule: str) -> pd.DataFrame:
    """
    指定周期へリサンプル（OHLCV的な集約）。
    """
    return (
        src.resample(rule)
        .agg(
            {
                "open": "first",
                "high": "max",
                "low": "min",
                "close": "last",
                "tickvol": "sum",
                "spread_or_zero": "mean",
            }
        )
        .dropna()
    )


def atr(ohlc: pd.DataFrame, period: int = 14) -> pd.Series:
    """
    ATR(14)をEMAで計算（高値-安値、ギャップを考慮）。
    """
    high = ohlc["high"]
    low = ohlc["low"]
    close = ohlc["close"]
    prev = close.shift(1)
    tr = pd.concat([(high - low).abs(), (high - prev).abs(), (low - prev).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False).mean()


def ema(series: pd.Series, span: int) -> pd.Series:
    """EMAの簡易ラッパー。"""
    return series.ewm(span=span, adjust=False).mean()


def compute_rsi3(close: pd.Series) -> pd.Series:
    """RSI(3)の簡易版（SMAで近似）。"""
    delta = close.diff()
    gain = delta.where(delta > 0, 0.0)
    loss = -delta.where(delta < 0, 0.0)
    roll_up = gain.rolling(3).mean()
    roll_dn = loss.rolling(3).mean()
    rs = roll_up / roll_dn.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))
    return rsi


def norm01_clip(x: pd.Series) -> pd.Series:
    """
    [-1,1]にクリップ → 0..1に正規化。
    Edgeスコアの位置・傾き正規化などに使用。
    """
    x = x.clip(-1, 1)
    return (x + 1) / 2


def compute_struct_score(m5: pd.DataFrame) -> pd.Series:
    """
    直近3本のHH/LLの組合せをスコア化。
    - up/dn が排他的に立つなら 1
    - 両方立つなら 0.5（揉み）
    - それ以外 0
    """
    struct = pd.Series(0, index=m5.index, dtype=float)
    for i in range(3, len(m5)):
        l1, l2, l3 = m5["low"].iloc[i - 1], m5["low"].iloc[i - 2], m5["low"].iloc[i - 3]
        h1b, h2b, h3b = m5["high"].iloc[i - 1], m5["high"].iloc[i - 2], m5["high"].iloc[i - 3]
        up = (h1b > max(h2b, h3b)) and (l1 >= min(l2, l3))
        dn = (l1 < min(l2, l3)) and (h1b <= max(h2b, h3b))
        if up != dn:
            struct.iloc[i] = 1.0
        elif up and dn:
            struct.iloc[i] = 0.5
    return struct


def compute_edge_base(m5: pd.DataFrame) -> pd.Series:
    """
    Edge 指標（0..1）を構築。
    - 位置（close-EMA20）/ (2*ATR)
    - 傾き（EMA20の3本差分）/ (3*ATR)
    - RSI3（0..1正規化）
    - 構造（compute_struct_score）
    重み：位置35%, 傾き25%, RSI25%, 構造15%
    """
    m5["ema20"] = ema(m5["close"], span=20)
    pos_raw = (m5["close"] - m5["ema20"]) / (2 * m5["atr"].replace(0, np.nan))
    slope_raw = (m5["ema20"] - m5["ema20"].shift(3)) / (3 * m5["atr"].replace(0, np.nan))
    rsi3 = compute_rsi3(m5["close"]).clip(0, 100)
    rsi_norm = (rsi3 / 100).clip(0, 1).fillna(0.5)
    struct_score = compute_struct_score(m5)

    edge = (
        0.35 * norm01_clip(pos_raw.fillna(0))
        + 0.25 * norm01_clip(slope_raw.fillna(0))
        + 0.25 * rsi_norm
        + 0.15 * struct_score
    )
    return edge


def compute_h1_pivots(h1: pd.DataFrame, k: int = 3) -> Tuple[pd.Series, pd.Series]:
    """
    H1 の左右k本ピボット（ユニーク極値のみTrue）をブールSeriesで返す。
    """
    piv_hi = pd.Series(False, index=h1.index)
    piv_lo = pd.Series(False, index=h1.index)
    for i in range(k, len(h1) - k):
        wh = h1["high"].iloc[i - k : i + k + 1]
        if h1["high"].iloc[i] == wh.max() and (wh == h1["high"].iloc[i]).sum() == 1:
            piv_hi.iloc[i] = True
        wl = h1["low"].iloc[i - k : i + k + 1]
        if h1["low"].iloc[i] == wl.min() and (wl == h1["low"].iloc[i]).sum() == 1:
            piv_lo.iloc[i] = True
    return piv_hi, piv_lo


def compute_beta_sigma(close: pd.Series, span: int = 48) -> pd.DataFrame:
    """
    H1クローズから、回帰傾きβと標準偏差σを算出。
    """
    xs = np.arange(span)
    xmean = xs.mean()
    xvar = ((xs - xmean) ** 2).mean()

    betas = []
    sigmas = []
    idxs = []
    for i in range(span - 1, len(close)):
        w = close.iloc[i - span + 1 : i + 1]
        y = w.values
        ymean = y.mean()
        cov = ((xs - xmean) * (y - ymean)).mean()
        beta = cov / xvar
        sigma = w.std()
        betas.append(beta)
        sigmas.append(sigma)
        idxs.append(close.index[i])
    return pd.DataFrame({"beta": betas, "sigma": sigmas}, index=idxs)


def build_regime_gate(h1_close: pd.Series, beta_window: int = 48, coef: float = 0.002) -> pd.Series:
    """
    従来ゲート（ヒステリシスなし）を返す。|β| >= σ×coef → TRD, else RNG
    """
    bs = compute_beta_sigma(h1_close, span=beta_window)
    gate = pd.Series(np.where(bs["beta"].abs() >= bs["sigma"] * coef, "TRD", "RNG"), index=bs.index)
    return gate


def build_regime_gate_hysteresis(
    h1_close: pd.Series, beta_window: int = 48, enter_coef: float = 0.0022, exit_coef: float = 0.0018
) -> pd.Series:
    """
    ヒステリシス付きゲートを返す。
    - TRDに入る：|β| ≥ σ×enter_coef
    - RNGに戻る：|β| ≤ σ×exit_coef
    """
    bs = compute_beta_sigma(h1_close, span=beta_window)
    state = []
    prev = "RNG"
    for t, (b, s) in bs[["beta", "sigma"]].iterrows():
        if prev == "RNG":
            cur = "TRD" if abs(b) >= s * enter_coef else "RNG"
        else:
            cur = "RNG" if abs(b) <= s * exit_coef else "TRD"
        state.append(cur)
        prev = cur
    return pd.Series(state, index=bs.index)


# ============================================================
# TRDブレイク・シミュレーター本体
# ============================================================

def simulate_trd_breakout(
    m5: pd.DataFrame,
    h1: pd.DataFrame,
    regime_col: str,
    edge_entry: float = 0.60,
    entry_buffer_atr: float = 0.10,
    sl_extra_atr_h1: float = 0.12,
    struct_len: int = 3,
    burst_delta: float = 16.0,
    edge_exit_thr: float = 0.28,
    edge_exit_consec: int = 3,
    atr_cap_multiple: Optional[float] = 3.0,
) -> pd.DataFrame:
    """
    TRDゲート中のみ発注するブレイクアウト・シミュレーター。
    - ENTRY：HH/LLブレイク＋EntryBuffer
    - EXIT：SL → STRUCT → BURST → EDGE → END
    - SL：ピボット±ATRExtra、無い場合は (2.5+Extra)×ATR。ATRキャップ適用可。
    """
    trades = []
    inpos = False
    side = None
    ep = None
    et = None
    sl = None
    epbuf = None
    slp = None
    regime = None

    # H1ピボット検出（左右=3）
    piv_hi, piv_lo = compute_h1_pivots(h1, k=3)

    # H1の時刻配列（ATR/ピボット参照用）
    h1_times = list(h1.index)

    def h1_idx_at(t) -> Optional[int]:
        idx = None
        for i, ht in enumerate(h1_times):
            if ht <= t:
                idx = i
            else:
                break
        return idx

    for t, row in m5.iterrows():
        # ========== EXIT 判定 ==========
        if inpos:
            low = row["low"]
            high = row["high"]
            close = row["close"]
            idxm = m5.index.get_loc(t)

            exit_flag = False
            reason = None
            xp = None

            # 1) SL 到達
            if side == "LONG" and low <= sl:
                xp = sl
                reason = "SL"
                exit_flag = True
            if side == "SHORT" and high >= sl:
                xp = sl
                reason = "SL"
                exit_flag = True

            # 2) STRUCT（3本連続）
            if not exit_flag and idxm >= struct_len:
                lows = m5["low"].iloc[idxm - struct_len : idxm]
                highs = m5["high"].iloc[idxm - struct_len : idxm]
                if side == "LONG":
                    if all(lows.iloc[j] < lows.iloc[j - 1] for j in range(1, len(lows))):
                        xp = close
                        reason = f"STRUCT{struct_len}"
                        exit_flag = True
                else:
                    if all(highs.iloc[j] > highs.iloc[j - 1] for j in range(1, len(highs))):
                        xp = close
                        reason = f"STRUCT{struct_len}"
                        exit_flag = True

            # 3) BURST（ΔRSI >= 16 or <= -16）
            if not exit_flag and idxm >= 3:
                r1 = m5["rsi3"].iloc[idxm - 1]
                r2 = m5["rsi3"].iloc[idxm - 2]
                dr = r1 - r2
                if side == "LONG" and dr <= -burst_delta:
                    xp = close
                    reason = f"BURST{burst_delta}"
                    exit_flag = True
                if side == "SHORT" and dr >= burst_delta:
                    xp = close
                    reason = f"BURST{burst_delta}"
                    exit_flag = True

            # 4) EDGE（弱化の持続）
            if not exit_flag and idxm >= edge_exit_consec:
                under = True
                for k in range(1, edge_exit_consec + 1):
                    if m5["edge_base"].iloc[idxm - k] >= edge_exit_thr:
                        under = False
                        break
                if under:
                    xp = close
                    reason = f"EDGE{edge_exit_thr}x{edge_exit_consec}"
                    exit_flag = True

            # 実際のクローズ
            if exit_flag:
                pnl = (xp - ep) if side == "LONG" else (ep - xp)
                trades.append(
                    {
                        "entry_time": et,
                        "exit_time": t,
                        "side": side,
                        "entry": ep,
                        "exit": xp,
                        "pnl_pips": pips(pnl),
                        "hold_bars": int((t - et).total_seconds() // (5 * 60)) + 1,
                        "entry_buf": epbuf,
                        "sl_pips": slp,
                        "regime": regime,
                        "exit_reason": reason,
                    }
                )
                inpos = False
                continue

        # ========== ENTRY 判定 ==========
        if not inpos:
            # TRDゲート中のみ
            if row[regime_col] != "TRD":
                continue
            # Edge品質フィルタ
            if np.isnan(row["edge_base"]) or row["edge_base"] < edge_entry:
                continue
            if row["atr"] <= 0 or np.isnan(row["atr"]):
                continue

            hh = row["hh"]
            ll = row["ll"]
            close = row["close"]
            if np.isnan(hh) or np.isnan(ll):
                continue

            if close > hh:
                side = "LONG"
                buf = entry_buffer_atr * row["atr"]
                ep = hh + buf
            elif close < ll:
                side = "SHORT"
                buf = entry_buffer_atr * row["atr"]
                ep = ll - buf
            else:
                continue

            et = t
            epbuf = pips(buf)
            inpos = True
            regime = row[regime_col]

            # 初期 SL の決定（H1 ピボット優先、無い場合はスイング方式）
            hi = h1_idx_at(t)
            atrh = h1["atr"].iloc[hi] if hi is not None else h1["atr"].iloc[-1]

            if side == "LONG":
                swing = None
                if hi is not None:
                    for k in range(hi, -1, -1):
                        if piv_lo.iloc[k] and h1["low"].iloc[k] < ep:
                            swing = h1["low"].iloc[k]
                            break
                if swing is not None:
                    sl_pivot = swing - sl_extra_atr_h1 * atrh
                else:
                    sl_pivot = ep - (2.5 + sl_extra_atr_h1) * atrh

                if atr_cap_multiple is not None:
                    sl_cap = ep - atr_cap_multiple * atrh
                    # ロングなので「より上側」を選んで距離を短縮（= max）
                    sl = max(sl_pivot, sl_cap)
                else:
                    sl = sl_pivot

                slp = pips(ep - sl)

            else:
                swing = None
                if hi is not None:
                    for k in range(hi, -1, -1):
                        if piv_hi.iloc[k] and h1["high"].iloc[k] > ep:
                            swing = h1["high"].iloc[k]
                            break
                if swing is not None:
                    sl_pivot = swing + sl_extra_atr_h1 * atrh
                else:
                    sl_pivot = ep + (2.5 + sl_extra_atr_h1) * atrh

                if atr_cap_multiple is not None:
                    sl_cap = ep + atr_cap_multiple * atrh
                    # ショートなので「より下側」を選んで距離を短縮（= min）
                    sl = min(sl_pivot, sl_cap)
                else:
                    sl = sl_pivot

                slp = pips(sl - ep)

    # ========== 終端クローズ ==========
    if inpos:
        last = m5.index[-1]
        lc = m5.iloc[-1]["close"]
        pnl = (lc - ep) if side == "LONG" else (ep - lc)
        trades.append(
            {
                "entry_time": et,
                "exit_time": last,
                "side": side,
                "entry": ep,
                "exit": lc,
                "pnl_pips": pips(pnl),
                "hold_bars": int((last - et).total_seconds() // (5 * 60)) + 1,
                "entry_buf": epbuf,
                "sl_pips": slp,
                "regime": regime,
                "exit_reason": "END",
            }
        )

    return pd.DataFrame(trades)


def summarize_trades(td: pd.DataFrame, label: str) -> Dict[str, float]:
    """取引結果のサマリ統計を返す。"""
    if td is None or len(td) == 0:
        return {"profile": label, "trades": 0}

    wins = td[td["pnl_pips"] > 0]
    avg_sl = td["sl_pips"].mean()
    avg_r = td["pnl_pips"].mean() / avg_sl if avg_sl and avg_sl != 0 else np.nan

    return {
        "profile": label,
        "trades": float(len(td)),
        "win_rate_%": float((td["pnl_pips"] > 0).mean() * 100),
        "avg_pnl_pips": float(td["pnl_pips"].mean()),
        "median_pnl_pips": float(td["pnl_pips"].median()),
        "min_pnl_pips": float(td["pnl_pips"].min()),
        "max_pnl_pips": float(td["pnl_pips"].max()),
        "avg_hold_bars": float(td["hold_bars"].mean()),
        "median_hold_bars": float(td["hold_bars"].median()),
        "avg_SL_pips": float(avg_sl),
        "median_SL_pips": float(td["sl_pips"].median()),
        "avg_R_per_trade": float(avg_r) if pd.notna(avg_r) else np.nan,
        "winners_avg": float(wins["pnl_pips"].mean()) if len(wins) else np.nan,
        "winners_median": float(wins["pnl_pips"].median()) if len(wins) else np.nan,
        "winners_max": float(wins["pnl_pips"].max()) if len(wins) else np.nan,
    }


# ============================================================
# ランナー（各検証メニュー）
# ============================================================

def prepare_frames(csv_path: str) -> Tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """M1のCSVから M5/H1 を作成し、指標を一括生成して返す。"""
    df = read_m1_csv(csv_path)
    m5 = resample_ohlc(df, "5T")
    h1 = resample_ohlc(df, "1H")

    # 基本指標
    m5["atr"] = atr(m5)
    h1["atr"] = atr(h1)
    m5["rsi3"] = compute_rsi3(m5["close"])
    m5["edge_base"] = compute_edge_base(m5)

    # HH/LL（6本、1本シフト）
    LB = 6
    m5["hh"] = m5["high"].rolling(LB).max().shift(1)
    m5["ll"] = m5["low"].rolling(LB).min().shift(1)

    # レジーム（従来／ヒステリシス）
    gate_no = build_regime_gate(h1["close"], beta_window=48, coef=0.002)
    gate_hys = build_regime_gate_hysteresis(h1["close"], beta_window=48, enter_coef=0.0022, exit_coef=0.0018)
    m5["regime_no"] = gate_no.reindex(m5.index, method="ffill")
    m5["regime_hys"] = gate_hys.reindex(m5.index, method="ffill")

    return df, m5, h1


def run_hybrid(csv_path: str, outdir: Path, params: Dict):
    """ハイブリッド出口ロジックで1本走らせる（ヒステリシス=regime_hys、ATRcap使用）。"""
    _, m5, h1 = prepare_frames(csv_path)
    td = simulate_trd_breakout(
        m5,
        h1,
        regime_col="regime_hys",
        edge_entry=params.get("edge_entry", 0.60),
        entry_buffer_atr=params.get("entry_buffer", 0.10),
        sl_extra_atr_h1=params.get("sl_extra", 0.12),
        struct_len=params.get("struct_len", 3),
        burst_delta=params.get("burst_delta", 16.0),
        edge_exit_thr=params.get("edge_exit_thr", 0.28),
        edge_exit_consec=params.get("edge_exit_consec", 3),
        atr_cap_multiple=params.get("atr_cap", 3.0),
    )
    summary = pd.DataFrame([summarize_trades(td, "hybrid")]).round(3)

    # 画面表示（Notebook環境ではテーブルで見える）
    try:
        from caas_jupyter_tools import display_dataframe_to_user

        display_dataframe_to_user("ハイブリッドEXIT：サマリ", summary)
        display_dataframe_to_user("ハイブリッドEXIT：取引一覧", td)
    except Exception:
        pass

    # Excel保存
    outpath = outdir / "hybrid_exit_result.py.xlsx"
    with pd.ExcelWriter(outpath, engine="xlsxwriter") as w:
        summary.to_excel(w, sheet_name="summary", index=False)
        td.to_excel(w, sheet_name="trades", index=False)
    print(f"[saved] {outpath}")


def run_atr_sweep(csv_path: str, outdir: Path, caps: List[float]):
    """ATRキャップのリストを一気に比較（2.0 / 3.0 / 4.0 など）。"""
    _, m5, h1 = prepare_frames(csv_path)
    rows = []
    all_trades = []

    for c in caps:
        td = simulate_trd_breakout(
            m5,
            h1,
            regime_col="regime_hys",
            atr_cap_multiple=c,
        )
        td["profile"] = f"cap{c}"
        rows.append(summarize_trades(td, f"cap{c}"))
        all_trades.append(td)

    summary_df = pd.DataFrame(rows).round(3)
    all_trades_df = pd.concat(all_trades, ignore_index=True)

    try:
        from caas_jupyter_tools import display_dataframe_to_user

        display_dataframe_to_user("ATRキャップ比較：サマリ", summary_df)
        display_dataframe_to_user("ATRキャップ比較：全取引", all_trades_df)
    except Exception:
        pass

    outpath = outdir / "atr_cap_step_compare.py.xlsx"
    with pd.ExcelWriter(outpath, engine="xlsxwriter") as w:
        summary_df.to_excel(w, sheet_name="summary", index=False)
        for c in caps:
            lab = f"cap{c}"
            all_trades_df[all_trades_df["profile"] == lab].to_excel(w, sheet_name=lab[:31], index=False)
    print(f"[saved] {outpath}")


def run_gate_compare(csv_path: str, outdir: Path, enter_coef: float, exit_coef: float, atr_cap: float):
    """ゲート：従来 vs ヒステリシス の比較（ATRcap固定）。"""
    _, m5, h1 = prepare_frames(csv_path)
    rows = []
    all_trades = []

    for regime_col, label in [("regime_no", "no_hysteresis"), ("regime_hys", "with_hysteresis")]:
        td = simulate_trd_breakout(
            m5,
            h1,
            regime_col=regime_col,
            atr_cap_multiple=atr_cap,
        )
        td["profile"] = label
        rows.append(summarize_trades(td, label))
        all_trades.append(td)

    summary_df = pd.DataFrame(rows).round(3)
    all_trades_df = pd.concat(all_trades, ignore_index=True)

    # ゲート切替回数とTRD滞在率（H1基準）
    bs_no = build_regime_gate(h1["close"], beta_window=48, coef=0.002)
    bs_hy = build_regime_gate_hysteresis(h1["close"], beta_window=48, enter_coef=enter_coef, exit_coef=exit_coef)

    def count_switches(series: pd.Series) -> int:
        return int((series.shift(1) != series).sum())

    gate_stats = pd.DataFrame(
        {
            "metric": ["H1_gate_switches", "TRD_ratio(%)"],
            "no_hysteresis": [count_switches(bs_no), (bs_no == "TRD").mean() * 100],
            "with_hysteresis": [count_switches(bs_hy), (bs_hy == "TRD").mean() * 100],
        }
    )

    try:
        from caas_jupyter_tools import display_dataframe_to_user

        display_dataframe_to_user("ゲート比較：サマリ", summary_df)
        display_dataframe_to_user("ゲート比較：ゲート切替回数など（H1）", gate_stats)
        display_dataframe_to_user("ゲート比較：全取引", all_trades_df)
    except Exception:
        pass

    outpath = outdir / "gate_hysteresis_compare.py.xlsx"
    with pd.ExcelWriter(outpath, engine="xlsxwriter") as w:
        summary_df.to_excel(w, sheet_name="summary", index=False)
        gate_stats.to_excel(w, sheet_name="gate_stats", index=False)
        all_trades_df[all_trades_df["profile"] == "no_hysteresis"].to_excel(
            w, sheet_name="no_hysteresis", index=False
        )
        all_trades_df[all_trades_df["profile"] == "with_hysteresis"].to_excel(
            w, sheet_name="with_hysteresis", index=False
        )
    print(f"[saved] {outpath}")


# ============================================================
# CLI
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="TRDブレイク研究用シミュレーター")
    parser.add_argument("--csv", type=str, required=True, help="USDJPY M1 CSV のパス")
    parser.add_argument("--run", type=str, choices=["hybrid", "atr_sweep", "gate"], required=True)
    parser.add_argument("--out", type=str, default="/mnt/data", help="出力フォルダ")

    # 共通パラメータ（必要に応じて利用）
    parser.add_argument("--entry_buffer", type=float, default=0.10)
    parser.add_argument("--edge_entry", type=float, default=0.60)
    parser.add_argument("--sl_extra", type=float, default=0.12)
    parser.add_argument("--struct_len", type=int, default=3)
    parser.add_argument("--burst_delta", type=float, default=16.0)
    parser.add_argument("--edge_exit_thr", type=float, default=0.28)
    parser.add_argument("--edge_exit_consec", type=int, default=3)
    parser.add_argument("--atr_cap", type=float, default=3.0)

    # ATRスイープ用
    parser.add_argument("--caps", type=float, nargs="*", default=[2.0, 3.0, 4.0])

    # ヒステリシス用
    parser.add_argument("--enter_coef", type=float, default=0.0022)
    parser.add_argument("--exit_coef", type=float, default=0.0018)

    args = parser.parse_args()

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    if args.run == "hybrid":
        run_hybrid(
            args.csv,
            outdir,
            params=dict(
                entry_buffer=args.entry_buffer,
                edge_entry=args.edge_entry,
                sl_extra=args.sl_extra,
                struct_len=args.struct_len,
                burst_delta=args.burst_delta,
                edge_exit_thr=args.edge_exit_thr,
                edge_exit_consec=args.edge_exit_consec,
                atr_cap=args.atr_cap,
            ),
        )

    elif args.run == "atr_sweep":
        run_atr_sweep(args.csv, outdir, caps=args.caps)

    elif args.run == "gate":
        run_gate_compare(args.csv, outdir, enter_coef=args.enter_coef, exit_coef=args.exit_coef, atr_cap=args.atr_cap)


if __name__ == "__main__":
    # Notebook から呼ぶ場合は argparse を避けるために try/except にしています。
    try:
        main()
    except SystemExit:
        # argparse が Jupyter で投げる SystemExit を握りつぶす（Notebook実行向け）
        pass
