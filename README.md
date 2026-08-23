# Stonkport

A single-page **trade journal** web app where **all UI is rendered by Godot 4.x's Control node system**, exported to WebAssembly and embedded in an HTML page. Fully client-side: everything revolves around **Trades** — groups of logs covering one position lifecycle (stock, crypto, or custom assets) — with performance analytics on top. No backend, no API keys.

## Features

- **Layout** — icon-only navigation rail on the right (Dashboard / Trades / Settings), a time-range filter bar on top, center workspace. The range bar hides while Settings is open.
- **Trades** — each trade holds chronological logs (`open` / `add` / `reduce` / `close`) with quantity, price and fee. State (`open` / `closed`), opening/closing timestamps, P/L amount and percent are derived from logs. List sorts by latest activity; state chips + asset search filter it; the square **+** button creates trades.
- **Dashboard** — win rate, expectancy, profit factor, avg win/loss hold time, current/max win streak, biggest win/loss, best performing asset, P/L by asset bars, recent closed trades — all respecting the time range.
- **Time range** — presets (All / 7D / 30D / 90D / YTD / 1Y) or custom From/To dates; defaults to all time.
- **Settings** — display currency (USD/EUR/GBP/JPY/CNY/CAD/AUD/CHF), CSV export & import (merge by id; paste-import works on web), clear-all-data with confirmation.
- **Mark pricing** — open stock/crypto trades mark to the built-in simulator price; custom assets use their last logged price.
- **Persistence** — `user://trades.json` (IndexedDB-backed localStorage on web); legacy v1 portfolio data migrates into trades on first run; demo journal seeds otherwise.

## Build

Requires Godot 4.3+ (developed against 4.7) with the **Web export templates** installed (Editor → Manage Export Templates).

```sh
godot --headless --path . --export-release "Web" build/web/index.html
```

VS Code: **Terminal → Run Task…** offers `Export: Web`, `Export: All Presets` (the default build task), and `Godot: Open Editor`.

## Use

Desktop:

```sh
godot --path .          # or open the project in the editor and press F5
```

Web — WASM requires correct MIME types, so serve over HTTP rather than `file://`:

```sh
cd build/web
python -m http.server 8080
# open http://localhost:8080
```

Windows exe:

```sh
godot --headless --path . --export-release "Windows Exe" build/windows/Stonkport.exe
```

Run `Stonkport.exe` — it serves the app from a built-in HTTP server on `127.0.0.1:17400`, opens it in your default browser, and lives in the system tray (left-click re-opens the web app; right-click offers Open Web App / Show Window / Quit).

### Journaling workflow

1. **Trades → +** — record asset, type, direction, opening quantity/price/fee/date.
2. While the position is open, log partial entries/exits from the edit dialog (**Add** / **Reduce**); **Close** prefills the remaining quantity at the current mark.
3. Closed trades feed every Dashboard statistic; the time-range bar scopes everything by activity date.

### CSV format

```csv
id,asset,asset_type,direction,state,opened_at,closed_at,quantity,entry_price,exit_price,fees,pnl,pnl_pct,notes
,AAPL,stock,long,closed,2026-06-01,2026-06-20,15,170.10,189.75,2.50,289.65,+11.35,,swing trade
```

Dates are `YYYY-MM-DD`. On import, rows rebuild minimal logs (one open, optionally one close) and recompute state/P/L; existing ids are skipped when merging.
