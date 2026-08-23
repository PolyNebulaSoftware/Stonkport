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

VS Code: **Terminal → Run Task…** offers `Export: Web`, `Export: Windows Exe`, `Export: All Presets` (the default build task), and `Godot: Open Editor` — see [`.vscode/tasks.json`](.vscode/tasks.json); they wrap [`tools/export_presets.cmd`](tools/export_presets.cmd) and [`tools/open_editor.cmd`](tools/open_editor.cmd).

WASM requires correct MIME types, so serve over HTTP rather than `file://`. The export uses a custom HTML shell (`web/index.html`) with a loading bar; thread support is disabled so no COOP/COEP headers are needed.

## Windows launcher (tray)

The same project also exports a Windows exe that lives in the system tray and serves the web build locally:

```sh
godot --headless --path . --export-release "Web" web_dist/index.html            # build the web assets first
godot --headless --path . --export-release "Windows Exe" build/windows/LocalStoport.exe
```

Run `LocalStoport.exe` and it minimizes straight to the tray via the built-in `StatusIndicator` node. Left-click the tray icon to serve `web_dist/` from a tiny built-in HTTP server on `127.0.0.1:17400` and open it in your default browser — fully offline, no Python needed. Right-click for **Open Web App / Show Window / Quit**; closing the window hides to tray instead of quitting. Launching a second copy just reveals the running one in the browser and exits. The web build is packed into the exe (`embed_pck`), but a `web_dist/` folder next to the exe takes precedence if present.

## Hosting (GitHub Pages)

Every push to `main` rebuilds the web export with the [godot-ci](https://github.com/marketplace/actions/godot-ci) action and deploys it as a Pages site — see [`.github/workflows/deploy-pages.yml`](.github/workflows/deploy-pages.yml). One-time setup: repo **Settings → Pages → Source: GitHub Actions**. The app then lives at `https://<user>.github.io/<repo>/`; if the loading bar stalls after a deploy, hard-refresh once to bust a cached `index.pck`.

## Verify persistence

Add/edit/remove positions in the browser, then refresh the page — the portfolio reloads from IndexedDB. On desktop it round-trips through `%APPDATA%/Godot/app_userdata/LocalStoport/portfolio.json`.

## Project structure

```
project.godot                  # autoloads, stretch settings, gl_compatibility
export_presets.cfg             # "Web" + "Windows Exe" presets
data/stocks.json               # stock universe (ticker, name, sector, base price, volatility)
scenes/                        # main shell, screens, dialogs (UI built in code)
scripts/
├── autoload/
│   ├── market_simulator.gd    # price engine: tick loop, OHLCV history, movers
│   └── portfolio_manager.gd   # state, derived metrics, transactions, save/load
├── chart/
│   ├── candlestick_chart.gd   # custom _draw() candles/volume/crosshair/tooltip
│   └── donut_chart.gd         # custom _draw() allocation donut
├── tray/                      # Windows launcher: StatusIndicator tray icon + localhost web server
├── ui/                        # screen + dialog scripts
└── util.gd                    # money/pct formatting, palette constants
theme/theme.tres               # dark theme (GitHub-dark inspired)
web/index.html                 # custom export shell with loading progress
```

## Notes

- All market data is simulated; nothing here is financial advice.
- Prices follow `price *= exp(-0.5σ²·dt + σ·√dt·z)` where σ is each ticker's daily volatility and dt scales with the refresh interval.
