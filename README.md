# Stonkport

A single-page stock portfolio web app where **all UI is rendered by Godot 4.x's Control node system**, exported to WebAssembly and embedded in an HTML page. Fully client-side: mock market data comes from a built-in simulator, and portfolio state persists to the browser via `user://` (IndexedDB on the web). No backend, no API keys.

## Features

- **Dashboard** — total value, cash, day change, total P&L cards + sector allocation donut + top movers
- **Holdings** — add / edit / remove positions with buy/sell transaction history and validation
- **Chart** — candlestick chart with volume bars, crosshair tooltip, live last-price marker, timeframes (1D / 1W / 1M / 1Y)
- **Watchlist** — live prices; click a ticker to jump to its chart
- **Persistence** — `user://portfolio.json` (IndexedDB on web, localStorage fallback); demo portfolio seeded on first run
- **Market simulator** — geometric random walk with per-ticker volatility; deterministic synthetic OHLCV history anchored to the live price

## Build

Requires Godot 4.3+ (developed against 4.6) with the **Web export templates** installed (Editor → Manage Export Templates).

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

Add/edit/remove positions under **Holdings**, watch prices under **Watchlist**, then refresh the page — the portfolio reloads from IndexedDB (on desktop: `%APPDATA%/Godot/app_userdata/Stonkport/portfolio.json`).
