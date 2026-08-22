# LocalStoport

A single-page stock portfolio web app where **all UI is rendered by Godot 4.x's Control node system**, exported to WebAssembly and embedded in an HTML page. Fully client-side: mock market data comes from a built-in simulator, and portfolio state persists to the browser via `user://` (IndexedDB on the web). No backend, no API keys.

## Features

- **Dashboard** — total value, cash, day change, total P&L cards + sector allocation donut + top movers
- **Holdings** — add / edit / remove positions with buy/sell transaction history and validation
- **Chart** — candlestick chart with volume bars, crosshair tooltip, live last-price marker, timeframes (1D / 1W / 1M / 1Y)
- **Watchlist** — live prices; click a ticker to jump to its chart
- **Persistence** — `user://portfolio.json` (IndexedDB on web, localStorage fallback); demo portfolio seeded on first run
- **Market simulator** — geometric random walk with per-ticker volatility; deterministic synthetic OHLCV history anchored to the live price

## Requirements

- Godot 4.3+ (developed against 4.6) with the **Web export templates** installed (Editor → Manage Export Templates)

## Run (desktop)

```sh
godot --path .          # or open the project in the editor and press F5
```

## Export & serve (web)

```sh
godot --headless --path . --export-release "Web" build/web/index.html
cd build/web
python -m http.server 8080
# open http://localhost:8080
```

WASM requires correct MIME types, so serve over HTTP rather than `file://`. The export uses a custom HTML shell (`web/index.html`) with a loading bar; thread support is disabled so no COOP/COEP headers are needed.

## Verify persistence

Add/edit/remove positions in the browser, then refresh the page — the portfolio reloads from IndexedDB. On desktop it round-trips through `%APPDATA%/Godot/app_userdata/LocalStoport/portfolio.json`.

## Project structure

```
project.godot                  # autoloads, stretch settings, gl_compatibility
export_presets.cfg             # "Web" HTML5 preset
data/stocks.json               # stock universe (ticker, name, sector, base price, volatility)
scenes/                        # main shell, screens, dialogs (UI built in code)
scripts/
├── autoload/
│   ├── market_simulator.gd    # price engine: tick loop, OHLCV history, movers
│   └── portfolio_manager.gd   # state, derived metrics, transactions, save/load
├── chart/
│   ├── candlestick_chart.gd   # custom _draw() candles/volume/crosshair/tooltip
│   └── donut_chart.gd         # custom _draw() allocation donut
├── ui/                        # screen + dialog scripts
└── util.gd                    # money/pct formatting, palette constants
theme/theme.tres               # dark theme (GitHub-dark inspired)
web/index.html                 # custom export shell with loading progress
```

## Notes

- All market data is simulated; nothing here is financial advice.
- Prices follow `price *= exp(-0.5σ²·dt + σ·√dt·z)` where σ is each ticker's daily volatility and dt scales with the refresh interval.
