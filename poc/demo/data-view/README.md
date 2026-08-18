# AmisAd — the data-view demo

Two synchronized browser windows and a slide deck, served by one PowerShell
script, on the topology a green [`test/amisad.end-to-end.yml`](../../../test/amisad.end-to-end.yml)
run leaves live. Where [`by-act`](../by-act/) walks the ten scenarios through
persona buttons, this demo adds the thing the audience actually wonders about:
**what the machine knows, while it happens.**

| Window | URL | What |
|--------|-----|------|
| Actions | `http://<host-ip>:8092/` | All ten scenarios as a persona swimlane chart -- the whole 30 minutes visible as ghost slots from the first second -- plus the runner that executes the selected step |
| Data | `http://<host-ip>:8092/data` | Live processes and data structures on `amisad-core`, `amisad-edge-a`, `amisad-edge-b`, flashing as steps change them, with the privacy strip on top |
| Deck | `http://<host-ip>:8092/slides.html` | 18 slides, at most three short bullets each; the narration lives in the presenter notes (**S**) |

Both demos can coexist -- they use different ports and different browser
storage -- but do not drive both against the same lab during a presentation, or
the timeline will show only half the story.

## Prerequisites

- The end-to-end run finished green and the machines are still up:
  `amisad-core` (services on NodePorts 30080-30089) and both edges running
  `slice-runtime`. If a VM rebooted since, re-arm per
  [demo.md](../../demo.md#driving-the-demo) first.
- A Yuruna checkout -- the persona passwords are read from its authentication
  vault, and VM power state and IPs come from its host driver. It is discovered
  automatically (`-YurunaRoot` -> `YURUNA_ROOT` -> `YURUNA_CONFIG_PATH` -> the
  `<root>/project` clone layout -> `~/git/yuruna`, where the bootstrap
  installers clone on every platform); pass `-YurunaRoot` for anything else.
  Without it the windows, the
  proxy and the deck all still work; only the passwords and the VM power states
  are lost.

## Start

```powershell
pwsh poc/demo/data-view/serve-data-view.ps1              # add -CoreIp/-EdgeAIp/-EdgeBIp if auto-detect fails
pwsh poc/demo/data-view/serve-data-view.ps1 -BindAddress localhost   # this machine only
```

The banner prints the exact URLs to type, including the host's own addresses
when bound to the network.

## Presenting from another machine

`-BindAddress any` (the default) binds every interface; `-BindAddress 10.0.0.5`
binds one NIC (localhost stays bound too, so the host's own browser keeps
working). The server handles the host-side plumbing itself:

- **It opens inbound 8092** on whichever firewall the platform runs and, on
  Windows, adds the http.sys reservation a non-loopback listener needs. The
  change is announced before it happens, is idempotent, and downgrades to a
  warning if declined; `-SkipFirewall` opts out when the port is already open
  or policy forbids the change.
- If that step was declined or the bind still fails on Windows, register the
  reservation once by hand from an elevated shell:
  `netsh http add urlacl url=http://+:8092/ user=<domain>\<user>`.

`/api/personas` returns the vault passwords in the clear for the identity card,
so they are gated on the **client**, not the binding: loopback requests (the
host's own browser) always get them, everyone else sees
`<withheld: remote viewer>`. Add `-SharePersonaPasswords` to serve them to
remote viewers too -- on a trusted network, since anything that can reach the
port then gets them.

## Stage setup

Projector on **`/data`**; laptop or tablet on **`/`** with the deck beside it,
notes toggled on. The data window carries a compact copy of the timeline at the
bottom, so a single projector still shows the parallel-persona picture the deck
points at. With two displays, project `/data` and `/` side by side.

Everything is touch-ready: the runner's targets are finger-sized, timeline slots
are tappable (tapping someone else's slot switches to that persona), and the
deck takes horizontal swipes. Both windows are known-good back to Safari 13.1 /
iPadOS 13.

Any number of viewers can open either window; they all rebuild the same
timeline from the server's journal.

## Reset demo

The **Reset demo** button sits in the header of *both* windows. One confirm,
and it:

- clears the timeline, captured ids and check-marks in **every open window**
  (it goes through the server journal, not just local storage);
- **re-arms the buyer's participation consent** -- the coordinator refuses a need
  with `403 participation revoked` whenever the newest consent entry for her
  subject is a revoke, and that state is durable, so a pause left behind by an
  earlier run (or by `s003`) would otherwise refuse her very first step. Only
  the grant types that actually read `revoked` are re-granted, keeping the
  grant -> revoke -> re-grant history that `s003` puts on screen clean;
- leaves the lab's own records -- offers, orders, ledgers -- untouched.

The action window also re-runs that consent check at load, and reports it in the
header.

## The privacy strip

The three cells across the top of the data window answer the question the
audience is really asking, continuously and by machine:

1. **The buyer on the wire** -- the pseudonymous subject
   `sha256("maya|person|subject")[:16]`. That is the only handle the
   coordinator, the ledger and every box on screen have for her.
2. **Her identity, anywhere** -- a scanner over every lab response the window
   receives, looking for her login (whole-word, so `participation` never trips
   `pat`) and for personal-data field names. It should read `0 hits` for the
   whole demo. Supply-side names are excluded deliberately: `elena-atelier` is a
   public tenant id and `kai` a public creator credit -- catalog data, not buyer
   data. If this cell ever goes red, that is a real finding; do not explain it
   away.
3. **What she chose to share** -- the one-line context she wrote *does* travel:
   the seller's order board and the slice's egress log both carry it, because
   that half of the envelope is hers to share. Counting where it appears, next
   to an identity count of zero, is the whole thesis.

The private half of the envelope -- budget, deadline, constraints -- is logged
nowhere at all. It exists in flight and inside the sealed environment, which is
why no box can show it.

## What the boxes can and cannot show

Every box reads exactly one **GET** endpoint. The data window never issues a
POST to the lab -- not even the state-reporting ones, because several of those
write (an aggregation cycle records itself, certification appends to the
auditor's access log, minting a token accumulates one). A dashboard must not
change what it observes.

Some state is deliberately unreachable, and the demo says so rather than faking
it: the coordinator's open-need contents and handles (only a consent-gated
*count* is exposed), shortlists, held over-cap approvals, mandate scopes (the
consent chain shows the grant *event*, never its terms), connect partners and
credentials, seller stock numbers, issued identity tokens, and insights cells
below the anonymity threshold. **That invisibility is the product**, so those
boxes carry a caption saying what is not visible instead of a number.

`amisad-edge-b` stays empty for the whole demo, on purpose: every need is
region-a and `s004` pins placement there, so no sealed environment ever runs on
it. Slide 15 turns that empty column into the point.

## The 30 minutes

| Segment | Scenes | Budget |
|---------|--------|--------|
| Intro (slides 1-4) | windows tour, cast | 3 min |
| Act I -- The Buyer Loop | s001 3' - s002 2.5' - s003 3' | 9 min |
| Act II -- The Economy | s005 3.5' - s006 2' - s007 1.5' - s009 1' | 8 min |
| Act III -- Trust & Operations | s004 3.5' - s008 2.5' - s010 2' | 8 min |
| Close (slide 18) | the strip, the timeline | 2 min |

Steps marked *(optional)* are the schedule buffer -- skip them freely, except
`s007`'s out-of-scope refusal, which slide 12 points at.

## Rehearsing

The lab's records are durable, so a re-run is not a fresh run: offers upsert
(publishing them again changes no count), and the ERP lamp's stock stays zeroed
in `seller-svc` memory until that pod restarts. The deck's stage directions are
therefore phrased as **states** ("the lamp is gone from the matchable catalog"),
not deltas. Rehearse on the same lab freely; restore the lab snapshot only if
you want the count-drop moments to land visibly.

## Troubleshooting

- **"amisad-core unresolved" in a header** -- restart with `-CoreIp <ip>` (find
  it on the VM with `hostname -I`).
- **Every buyer step returns 403 `participation revoked`** -- press **Reset
  demo**, which re-arms the consent; the header chip reports the result.
- **502/503 from a step, or a box marked stale** -- the proxy could not reach
  that VM. Check `/api/topology` and the VM cards; a red service dot on the core
  card is that NodePort not answering.
- **The timeline is empty after a server restart** -- the journal is in-memory
  by design. Open windows detect the restart within a second and rebuild
  themselves; the lab's own state is unaffected, and the notebook ids are
  recaptured by re-running the steps (or read from the still-live lab).
- **A laptop cannot reach `http://<host ip>:8092/`** -- confirm the banner lists
  the host IP; if it does, it is the host firewall (rerun without
  `-SkipFirewall`, or open inbound TCP 8092 manually).
- **s004 placement answers oddly** -- a rebooted core lost the in-memory edge
  registry; `s004`'s first step rebuilds it (that is why it is step 1).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
