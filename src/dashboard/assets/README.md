# Assets

Brand artwork for Rewindle. The build reads exactly one file from this folder, `dashboard-icon.ico`. The rest is here so the artwork can be re-exported and credited.

| File | Purpose |
| --- | --- |
| `dashboard-icon.ico` | The Windows application icon. `build.ps1` embeds it in the executable (`/win32icon`), so it is the icon of the program, of the shortcut the installer creates, and of the tray icon. It holds seven 32-bit, PNG-compressed frames: 16, 24, 32, 48, 64, 128 and 256 px. |
| `dashboard-icon.png` | A 1024 x 1024 px RGBA raster of the same icon with transparent corners, for places that need a bitmap, such as release pages, store listings and social previews. The build and the app do not read it. |

## Source of truth

[`web/public/rewindle-icon.svg`](../web/public/rewindle-icon.svg) is the source of truth for the icon. It is drawn on a 64 x 64 grid: a `#101927` rounded tile with a 1-unit `#2B4150` outline, a `#76D6C8` rewind arrow, and an off-white `#F6F4EE` check mark. Every raster in this folder shows that artwork.

[`web/public/rewindle-mark.svg`](../web/public/rewindle-mark.svg) is the same arrow and check in a single color (`#167C73`) with no tile, for places that need the bare mark.

## Re-exporting the rasters

Change the SVG first, then rebuild both rasters from it.

1. Render `dashboard-icon.png` at 1024 x 1024 px, leaving the area outside the tile transparent.
2. Render the SVG at 16, 24, 32, 48, 64, 128 and 256 px and pack the seven frames into `dashboard-icon.ico` as 32-bit PNG-compressed images, as the current file does. Render each size from the vector instead of shrinking the 1024 px PNG, so the small sizes stay crisp.
3. Run `build.ps1`, then check the new executable's icon in Explorer and in the system tray.

Please keep generation scratch files (chroma-key sources, size-comparison previews and the like) out of this folder. The SVG is the master, and the build needs only the ICO.

## License

The Rewindle icon, the mark, and every file in this folder are distributed under the same license as the rest of this project. See the license file in the repository root.
