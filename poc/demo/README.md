# AmisAd POC — the 30-minute guided demo

A persona-switching **mock UI** plus a **slide deck** that walk all ten
scenarios in half an hour, on the topology a green
[`test/amisad.end-to-end.yml`](../../test/amisad.end-to-end.yml) run leaves
live. Nothing here changes the existing POC code or the deployed system — the
UI drives the same NodePort APIs the sequences exercise
([demo.md](../demo.md)), just from a browser instead of `curl`.

## Prerequisites

- The end-to-end run finished green and the machines are still up:
  `amisad-core` (services on NodePorts 30080–30089) and both edges running
  `slice-runtime`. If a VM rebooted since, re-arm per
  [demo.md](../demo.md#driving-the-demo) first.
- Yuruna at `c:\git\yuruna` (or pass `-YurunaRoot`) — the persona passwords
  are read from its authentication vault, and VM IPs fall back to its status
  handoff files when Hyper-V queries fail.

## Start

```powershell
pwsh poc\demo\serve-demo.ps1            # add -CoreIp/-EdgeAIp/-EdgeBIp if auto-detect fails
```

Then open, on the host:

| URL | What |
|-----|------|
| `http://localhost:8091/` | The demo console (persona dropdown → scenario step buttons) |
| `http://localhost:8091/slides.html` | The deck. Arrows navigate; **N** toggles presenter notes (the operator cues live there) |

The server binds **localhost only** on purpose: `/api/personas` returns the
vault passwords in the clear for the persona identity cards.

## How it works

- `serve-demo.ps1` serves the static UI and deck, answers `/api/personas`
  (vault via the Yuruna authentication module) and `/api/topology` (VM IPs),
  and proxies `/api/core/<nodeport>/…` and `/api/edge-a|b/…` to the lab —
  the POC services send no CORS headers, so the browser goes same-origin
  through the proxy.
- `ui/app.js` holds the whole demo script: each scenario panel lists its
  steps in order with the acting persona on every row; the dropdown enables
  that persona's buttons. Ids returned by the system (match, handle,
  campaign, case, credential…) are captured into the **notebook**
  (localStorage) and reused by later steps — including across scenarios
  (s008 disputes the s001 order; s010 certifies the whole session).
- Buyer steps replicate `buyer-client`'s HTTP calls (token from
  identity-mock, needs as opaque envelopes) — no SSH, no binaries.
- All demo writes use `demo-` prefixed ids and demo-only categories
  (giftware, glassware, tableware, homegoods, lighting, ceramics,
  picnicware), so the walkthrough is deterministic on top of whatever durable
  state the automated run left, **without restoring snapshots mid-demo**.
  Re-running the demo on the same lab works the same way; "Reset demo state"
  clears only the browser notebook.

## The 30 minutes

| Segment | Scenes | Budget |
|---------|--------|--------|
| Intro (slides 1–4) | promise, topology, cast | 3 min |
| Act I — The Buyer Loop | s001 full · s002 brisk · s003 full | 9 min |
| Act II — The Economy | s005 full · s006, s007, s009 brisk | 8 min |
| Act III — Trust & Operations | s004 full · s008 full · s010 finale | 8 min |
| Close (slide 19) | the loop, closed | 2 min |

Steps marked *(optional)* in the UI are the schedule buffer — refusal
demonstrations (out-of-scope 4xx) and secondary views. Skip them freely; the
narrative holds without them.

## Troubleshooting

- **"amisad-core unresolved" in the console header** — restart with
  `-CoreIp <ip>` (find it on the VM with `hostname -I`).
- **503/502 from a step** — the proxy could not reach that VM; check it is
  running and the IP is right (`/api/topology`).
- **Persona card shows `<unavailable>`** — vault module import failed; check
  `-YurunaRoot`. The API steps still work; only the password display is lost.
- **s004 placement answers oddly** — a rebooted core lost the in-memory edge
  registry; the "Register both regions" step rebuilds it (that is why it is
  step 1 of the scene).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
