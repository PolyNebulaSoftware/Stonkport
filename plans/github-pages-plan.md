# GitHub Pages Compatibility — Restructure Plan

## Goal

Host the Godot WASM build of Stonkport on GitHub Pages at
`https://<user>.github.io/<repo>/` so the app has a permanent public URL,
while keeping the tray-launcher pipeline (`web_dist/` + Windows exe) intact.

## Why the current setup almost works already

| Requirement | Status |
|---|---|
| `.wasm` served as `application/wasm` | ✅ GitHub Pages sends correct MIME types |
| No COOP/COEP headers needed | ✅ thread support already disabled in the Web preset |
| Relative asset paths (subpath hosting) | ✅ custom shell [`web/index.html`](web/index.html) only uses `$GODOT_URL` / `$GODOT_CONFIG`, which resolve relatively |
| Single-page app, no routing | ✅ no 404-fallback complexity |

No code restructuring is required — this is packaging + CI work.

## Recommended strategy: GitHub Actions deployment (Option A)

Build artifacts stay out of git (`web_dist/` remains ignored); every push to
`main` exports a fresh build in CI and deploys it as a Pages artifact.
(Alternative Option B — committing a `/docs` folder — is noted at the bottom.)

## Changes

### 1. New: [`.github/workflows/deploy-pages.yml`](.github/workflows/deploy-pages.yml)

```yaml
name: Deploy to GitHub Pages
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - name: Install Godot 4.7.2 + export templates   # see notes below
        run: ...download linux editor zip + export_templates.tpz...
      - name: Import assets
        run: godot --headless --path . --import
      - name: Export Web
        run: godot --headless --path . --export-release "Web" web_dist/index.html
      - name: Add .nojekyll
        run: touch web_dist/.nojekyll
      - uses: actions/upload-pages-artifact@v3
        with: { path: web_dist }
      - id: deployment
        uses: actions/deploy-pages@v4
```

Implementation notes:
- Pin **Godot 4.7.2 stable** exactly (editor + `export_templates.tpz` from the
  godotengine/godot-builds GitHub releases — verify asset URLs during
  implementation; templates unpack to
  `~/.local/share/godot/export_templates/4.7.2.stable/`).
- The `--import` step is mandatory before headless export in a fresh checkout.
- `.nojekyll` prevents Jekyll from interfering with dotfiles/asset names.

### 2. Repo settings (manual, one-time)

Settings → Pages → **Source: GitHub Actions**. First deploy happens on the
next push to `main` (or via *Run workflow*).

### 3. [`export_presets.cfg`](export_presets.cfg) — no path change

Keep `export_path="build/web/index.html"` (unused by CI, which passes an
explicit target). Preset already has: custom shell, no threads, empty
include filter — all Pages-compatible.

### 4. Launcher module — intentionally untouched

[`tray_launcher.gd`](scripts/tray/tray_launcher.gd) keeps serving local
`web_dist/`; the hosted Pages URL is simply the online twin of the same
build. No coupling introduced.

### 5. [`README.md`](README.md)

New "Hosting (GitHub Pages)" section: live URL, how deploys trigger, how to
run locally (existing python/tray instructions unchanged).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| CI export fails on fresh checkout (missing `.godot/`) | Explicit `--import` step before export |
| Template/editor version drift | Version-pinned downloads in one place in the workflow |
| Browser-cached stale `index.pck` after deploys | Our server header only affects the tray server; Pages sets its own caching — document hard-refresh |
| Subpath 404s if anything absolute creeps into the shell | Audit `web/index.html` in review (currently clean) |

## Alternative Option B (no CI): commit a `/docs` folder

Set Web preset `export_path="docs/index.html"`, un-ignore `docs/`, add
`docs/.gdignore` so Godot doesn't import the exported PNGs as resources
(verify export still writes into an ignored dir), commit builds manually.
Rejected as primary: binary churn in git history + manual export discipline;
kept as fallback if Actions is unavailable.

## Implementation Todos

- [ ] Write `.github/workflows/deploy-pages.yml` (pin 4.7.2, verify release URLs)
- [ ] Update `README.md` hosting section
- [ ] Push to a branch, run workflow once, confirm green
- [ ] Enable Pages (Source: GitHub Actions) in repo settings
- [ ] Load the public URL, confirm progress bar completes (WASM MIME OK) and persistence round-trips

## Verification Checklist

1. Workflow green on first run; artifact contains `index.html/.js/.wasm/.pck/.nojekyll`.
2. Site loads at `https://<user>.github.io/<repo>/` with working loading bar.
3. DevTools network: `.wasm` response `Content-Type: application/wasm`.
4. Portfolio edits survive a page refresh (IndexedDB under the subpath origin).
5. Tray launcher flow still works locally after merge (no regression).
