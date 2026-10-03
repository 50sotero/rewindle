# Rewindle brand assets

**Rewindle — Backup you can verify.**

The rewind loop represents returning to a saved point in time. The check represents completed verification. The supporting line, “Keep creating. Come back anytime.”, is suitable for introductory artwork; operational screens always describe the actual backup and recovery evidence.

The editable SVG files are the source artwork. App icons are supplied as PNG and ICO for the Windows dashboard and installer (an ICNS export is kept for other platforms). The wordmarks use outlined Inter glyphs so they render consistently without a font installation.

## Files

| Asset | Use |
| --- | --- |
| `mark.svg`, `mark-mono.svg`, `mark-reversed.svg` | Small standalone identity, monochrome print, and dark backgrounds |
| `wordmark-dark.svg`, `wordmark-light.svg` | Product name on light and dark backgrounds |
| `lockup-dark.svg`, `lockup-light.svg` | Mark and product name together |
| `app-icon.svg`, `.png`, `.ico`, `.icns` | Editable source and platform app icons |
| `social-card.svg`, `social-card.png` | 1200 × 630 release and repository artwork |
| `tokens.json` | Product name, typography, color, and motion values |

## Visual direction

Ink navy and warm paper provide calm workspaces; teal identifies interactive controls. Status colors retain their meaning: green for completed checks, amber for attention, and red for failures. A green status must follow successful evidence from the backup engine.

Use Inter for interface copy and headings. The bundled font files and outlined wordmarks derive from Inter distributed by `@fontsource-variable/inter`; its SIL Open Font License is included in `fonts/OFL.txt`.

Leave at least one quarter of the mark's width clear around the mark or lockup. Do not distort the artwork, rotate the wordmark, or rely on color alone to convey a backup result. Use the app icon at small sizes; use the wordmark where the product name needs to be readable.

Motion explains state changes: a short entrance for navigation, a gliding selection indicator, expanding detail rows, and progress only during an active operation or a clearly labelled preview. Respect the system's reduced-motion preference. The actual Beautiful UI component sources and their license are in `src/dashboard/web/vendor/`.

## Rebuild

From the repository root, with Python 3 and Node.js 22:

```powershell
python -m pip install --target .cache/brand-tools -r brand/requirements.txt
npm ci --prefix brand
python brand/generate.py
node brand/render.mjs
```

`generate.py` regenerates the editable vectors. `render.mjs` regenerates the raster and platform icon files from those vectors. The committed assets are ready for building the app; these illustration tools are only needed when changing the identity.
