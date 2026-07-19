# AmisAd brand art

Canonical brand assets for every POC application. Copied from the amisad.com
site repository (`assets/`); update there first, then re-copy here.

| File | Use |
|------|-----|
| `icon.svg` | Vector logo (two overlapping circles + white star) - favicons, headers |
| `icon-64.png` | 64px raster logo - mobile app assets, small embeds |
| `palette.css` | CSS custom properties for the brand colors |
| `palette.json` | The same tokens for non-CSS consumers (Flutter, tooling) |

Consumers in this repo: `components/apps/web-spa/public/icon.svg` and
`src/brand.css`; `components/apps/buyer-flutter/assets/icon-64.png` and the
color constants in `lib/main.dart`. Keep them in sync with this folder.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 alius-git
