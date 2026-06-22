#!/usr/bin/env python3
"""Run regression analysis on model_training view."""
import asyncio, os, sys
import numpy as np
import pandas as pd

async def main():
    import asyncpg
    dsn = os.environ["PG_DSN"]
    conn = await asyncpg.connect(dsn)

    print("📊 Exporting model_training data...", flush=True)
    rows = await conn.fetch("SELECT * FROM model_training ORDER BY report_date")
    cols = list(rows[0].keys())
    df = pd.DataFrame([dict(r) for r in rows])
    # Force convert all numeric columns from Decimal to float
    for col in df.columns:
        if col in ["report_date", "sunrise", "sunset"]:
            continue
        if df[col].dtype == object or str(df[col].dtype) == "object":
            try:
                df[col] = df[col].astype(float)
            except (ValueError, TypeError):
                pass
    print(f"   {len(df)} rows, {len(cols)} columns", flush=True)
    print(f"📋 Columns: {cols}", flush=True)
    await conn.close()

    # ── Feature Engineering ──
    print("\n🧹 Engineering features...", flush=True)
    df["log_net_sales"] = np.log(df["net_sales"].clip(lower=1))
    df["temp_max_sq"] = df["peak_temp_c"] ** 2
    df["summer_x_temp"] = df["summer_hols"] * df["peak_temp_c"]
    df["is_weekend"] = (df["dow"].isin([5, 6])).astype(int)
    df["is_friday"] = (df["dow"] == 5).astype(int)
    df["is_saturday"] = (df["dow"] == 6).astype(int)
    df["is_sunday"] = (df["dow"] == 0).astype(int)
    df["is_summer_month"] = df["month"].isin([6, 7, 8]).astype(int)
    df["is_winter"] = df["month"].isin([1, 2]).astype(int)
    df["high_tide_lunch"] = df["high_tide_hour"].between(11, 14).astype(int)
    df["spring_tide"] = (df["tide_range"] >= 4.5).astype(int)

    model_cols = [
        "log_net_sales",
        "peak_temp_c", "temp_max_sq", "rain_mm", "hours_sunshine",
        "summer_hols", "school_holiday", "bank_holiday", "easter",
        "is_weekend", "is_friday", "is_saturday", "is_sunday",
        "is_winter", "is_summer_month",
        "high_tide_lunch", "spring_tide", "tide_range",
        "cpi",
    ]
    df_model = df[model_cols].dropna()
    print(f"   {len(df_model)} complete rows after dropna", flush=True)

    # ── Run OLS ──
    print("\n📈 OLS regression on log(NET sales)...", flush=True)
    import statsmodels.api as sm
    from sklearn.preprocessing import StandardScaler

    X = df_model.drop(columns=["log_net_sales"])
    y = df_model["log_net_sales"]
    X = sm.add_constant(X)
    model = sm.OLS(y, X).fit()
    print(model.summary())

    # ── Back-transformed interpretation ──
    print("\n📊 INTERPRETATION (% impact on sales):")
    print("=" * 75)
    for var in X.columns:
        if var == "const":
            continue
        coef = model.params[var]
        pval = model.pvalues[var]
        pct = (np.exp(coef) - 1) * 100
        stars = ""
        if pval < 0.001: stars = "***"
        elif pval < 0.01: stars = "**"
        elif pval < 0.05: stars = "*"
        elif pval < 0.1: stars = "."
        if var in ["peak_temp_c", "rain_mm", "hours_sunshine", "temp_max_sq", "tide_range", "cpi"]:
            print(f"  {var:25s}: {coef:+.4f}  →  {pct:+.1f}%/unit  p={pval:.4f} {stars}")
        else:
            print(f"  {var:25s}: {coef:+.4f}  →  {pct:+.1f}% when True  p={pval:.4f} {stars}")
    print(f"\n  R² = {model.rsquared:.3f}  |  Adj. R² = {model.rsquared_adj:.3f}")

    # ── Standardized importance ──
    print("\n📊 FEATURE IMPORTANCE (standardized coefficients):")
    print("=" * 75)
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X.drop(columns=["const"]))
    model_std = sm.OLS(y, sm.add_constant(X_scaled)).fit()
    importance = pd.DataFrame({
        "feature": X.columns[1:],
        "coef_std": model_std.params[1:],
        "pval": model.pvalues[X.columns[1:]].values,
    })
    importance["abs_coef"] = importance["coef_std"].abs()
    importance = importance.sort_values("abs_coef", ascending=False)
    for _, r in importance.iterrows():
        stars = ""
        if r["pval"] < 0.001: stars = "***"
        elif r["pval"] < 0.01: stars = "**"
        elif r["pval"] < 0.05: stars = "*"
        elif r["pval"] < 0.1: stars = "."
        print(f"  {r['feature']:25s}: {r['coef_std']:+.3f} (std)  p={r['pval']:.4f} {stars}")

    # ── Key findings summary ──
    print("\n🔑 KEY FINDINGS:")
    print("=" * 75)
    sig = importance[importance["pval"] < 0.05]
    for _, r in sig.iterrows():
        direction = "📈" if r["coef_std"] > 0 else "📉"
        print(f"  {direction} {r['feature']}: {r['coef_std']:+.3f} std (p={r['pval']:.4f})")

    print("\nDone.")

asyncio.run(main())
