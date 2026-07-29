# AmisAd POC — the 30-minute guided demo (by act)

A persona-switching **mock UI** plus a **slide deck** that walk all ten
scenarios in half an hour, on the topology a green
[`test/amisad.end-to-end.yml`](../../../test/amisad.end-to-end.yml) run leaves
live. Nothing here changes the existing POC code or the deployed system — the
UI drives the same NodePort APIs the sequences exercise
([demo.md](../../demo.md)), just from a browser instead of `curl`.

## Prerequisites

- The end-to-end run finished green and the machines are still up:
  `amisad-core` (services on NodePorts 30080–30089) and both edges running
  `slice-runtime`. If a VM rebooted since, re-arm per
  [demo.md](../../demo.md#driving-the-demo) first.
- A Yuruna checkout — the persona passwords are read from its authentication
  vault, and VM IPs fall back to its status handoff files when the host driver
  reports none. It is discovered automatically (`-YurunaRoot` → `YURUNA_ROOT` →
  `YURUNA_CONFIG_PATH` → the `<root>/project` clone layout → `c:\git\yuruna` on
  Windows, `~/git/yuruna` elsewhere); pass `-YurunaRoot` for anything else.

## Start

```powershell
pwsh poc/demo/by-act/serve-by-act.ps1            # add -CoreIp/-EdgeAIp/-EdgeBIp if auto-detect fails
```

The banner prints the exact URLs, led by this host's own address so they can
be typed on another machine:

| URL | What |
|-----|------|
| `http://<host-ip>:8091/` | The demo console (persona dropdown → scenario step buttons) |
| `http://<host-ip>:8091/slides.html` | The deck. **N**/**P** (or arrows, space, the left/right edge strips) navigate, **Home**/**End** jump to first/last, **S** toggles presenter notes (the operator cues live there). Each slide is a history entry, so the browser's Back button steps back through the deck |

The server serves the network by default, so those URLs work from another
machine as they stand; `-BindAddress localhost` restricts them to this host.

## Presenting from another machine

To let the lab host do the work while you drive from a laptop, bind the console
to the network:

```powershell
pwsh poc/demo/by-act/serve-by-act.ps1                     # every interface (default)
pwsh poc/demo/by-act/serve-by-act.ps1 -BindAddress 10.0.0.5  # one NIC (localhost stays bound too)
pwsh poc/demo/by-act/serve-by-act.ps1 -BindAddress localhost  # this machine only
```

The banner prints the exact `http://<host ip>:8091/` URLs to type on the
laptop. The server handles the host-side plumbing itself:

- **It opens inbound 8091** on whichever firewall the platform runs and, on
  Windows, adds the http.sys reservation a non-loopback listener needs. The
  change is announced before it happens, is idempotent, and downgrades to a
  warning if declined; `-SkipFirewall` opts out when the port is already open
  or policy forbids the change.
- If that step was declined or the bind still fails on Windows, register the
  reservation once by hand from an elevated shell:
  `netsh http add urlacl url=http://+:8091/ user=<domain>\<user>`.

`/api/personas` returns the vault passwords in the clear for the identity
cards, so they are gated on the **client**, not the binding: loopback requests
(the host's own browser) always get them, and everyone else sees
`<withheld: remote viewer>`. Add `-SharePersonaPasswords` to serve them to
remote viewers too — on a trusted network, since anything that can reach the
port then gets them.

Nothing else changes: the API steps, the proxy and the deck all work
identically for a remote browser. Note the **notebook is per browser**
(localStorage), so the machine you present from is the one that carries the
captured ids — driving one demo from two browsers splits the state.

## How it works

- `serve-by-act.ps1` serves the static UI and deck, answers `/api/personas`
  (vault via the Yuruna authentication module) and `/api/topology` (VM IPs
  from the framework's per-hypervisor host driver, so Hyper-V, KVM and UTM
  hosts all resolve),
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
- **Persona card shows `<unavailable>` or a `<vault error: …>`** — the
  framework checkout was not located, or the vault module import failed; pass
  `-YurunaRoot`. The startup banner prints the resolved path. The API steps
  still work; only the password display is lost.
- **The laptop cannot reach `http://<host ip>:8091/`** — confirm the banner
  lists the host IP. If it does and the laptop still times out, it is the host
  firewall: rerun without `-SkipFirewall`, or open inbound TCP 8091 manually.
- **Every buyer step returns 403 `participation revoked`** — the console
  re-grants Maya's signup consents at load and reports it in the header; a
  `bad` note there means the coordinator refused, so check `/api/topology` and
  that `amisad-core` is up.
- **s004 placement answers oddly** — a rebooted core lost the in-memory edge
  registry; the "Register both regions" step rebuilds it (that is why it is
  step 1 of the scene).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
