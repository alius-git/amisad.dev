# poc/demo/data-view — implementation prompt

<!-- LICENSEURI https://yuruna.link/license -->
<!-- Copyright (c) 2026 by Alisson Sol et al. -->

> **Status: IMPLEMENTED.** This document was the implementation prompt for
> `poc/demo/data-view/`; it is kept as the record of the design decisions the
> demo was built from. The shipped behavior is described in
> [README.md](README.md) -- where the two disagree, the README wins.

---

## 1. Mission

Build a second, data-forward AmisAd demo under `poc/demo/data-view/`. The
existing `poc/demo/by-act` walks the ten scenarios through persona buttons, but the
backend stays invisible -- the audience never sees what the machine knows,
which is precisely the product's claim. This demo makes the claim visible by
serving **two synchronized browser windows plus a minimal slide deck** from
one PowerShell server:

1. **The actions window** (`/`) -- every persona step of all ten scenarios,
   arranged as an EasyTimeline-style swimlane chart (one lane per persona,
   one slot per step, inspired by
   <https://en.wikipedia.org/wiki/Wikipedia:EasyTimeline>): the whole
   30-minute script is visible as ghost slots from the first second, and
   fills in lane by lane as steps execute -- the interleaving of personas
   over time IS the picture. Below the chart, a runner card executes the
   current step against the live lab.
2. **The data window** (`/data`) -- live boxes showing the processes and data
   structures of the three VMs (`amisad-core`, `amisad-edge-a`,
   `amisad-edge-b`): chain lengths, order boards, consent state, campaign
   budgets, incident queues, sealed-environment ingress/egress. Boxes flash
   as steps change them, each flash attributed to the persona and step that
   caused it. A permanent **privacy strip** answers the audience's real
   question -- *how much data about the buyer is navigating?* -- with a live,
   machine-checked answer: **outside the sealed environments, zero**.
3. **The deck** (`/slides.html`) -- at most **3 bullets** of at most **5
   words** per slide; the presenter voices everything else from the notes.

Total delivery: 30 minutes including slack, leaving the rest of the hour for
questions.

## 2. Hard constraints

- **Create files only under `poc/demo/data-view/`.** Do not modify anything
  in `poc/demo/`, `poc/components/`, `poc/test/`, or any deployed service.
  The lab topology left by a green `test/amisad.end-to-end.yml` run is used
  as-is.
- **Repository discipline:** all work in `/home/ytest/git/amisad.dev` (never
  in the per-cycle clone under `yuruna/project/`). Never `git commit` or
  `git push` -- leave the diff for operator review.
- **The data window is strictly read-only.** It may only issue GET requests
  to the lab (through the proxy). It must never call POST endpoints -- not
  even "state-reporting" ones (`/v1/consents/state`, `/v1/placements`,
  `/v1/aggregation/cycle`, `/v1/certify`, token minting): several of them
  write (aggregation records a cycle, certify appends to the audit access
  log, tokens accumulate in identity-mock), and a dashboard must not mutate
  what it observes. Everything it shows comes from the GET endpoints in section 7
  plus the server's own `/api/*` endpoints.
- **Do not inherit `poc/demo/by-act`'s consent-preflight side effect into the data
  window.** The actions window keeps the boot-time re-grant of Maya's
  revoked consents (it is an action surface); the data window must load with
  zero writes.
- **Different port, different storage keys.** Default port **8092** (8091
  belongs to `poc/demo/by-act`, and HttpListener prefixes are exclusive per port).
  localStorage keys `amisad-dv-state` / `amisad-dv-done` (the old demo owns
  `amisad-demo-state` / `amisad-demo-done`; a different port is a different
  origin, but keep the names distinct anyway so the two consoles are never
  confused in devtools).
- **Same lab ids as `poc/demo/by-act`.** Step bodies are copied verbatim (`demo-`
  prefixed offer ids, demo-only categories), so either console can re-run on
  the same durable lab state deterministically. Offers are upserts; repeats
  are safe.
- **Comment guardrail:** code comments state the technical "why" only --
  never reference this plan, its sections, the review, or any process
  artifact (workspace rule in `CLAUDE.md`). This applies to HTML comments
  and PowerShell help text too.
- **PowerShell Script Analyzer** must report no new findings relative to
  `poc/demo/by-act/serve-by-act.ps1`'s existing baseline (currently:
  PSAvoidUsingEmptyCatchBlock x1, PSUseSingularNouns x1, positional-param
  informationals). Match the existing style: `Write-Information
  -InformationAction Continue`, `Write-Warning` for degradation,
  `$ErrorActionPreference = 'Stop'`.
- **JavaScript:** plain ES2020, no build step, no external requests (all
  same-origin). `node --check` must pass on every `.js` file.
- **Brand:** re-mount `/art/` from `poc/components/art` exactly as
  `serve-by-act.ps1` does (path `../components/art` relative to the script --
  the same relative depth holds from `poc/demo/data-view/`). Use palette
  tokens (`--amisad-navy #2B3A67`, `--amisad-terracotta #E2725B`); do not
  fork values.

## 3. Deliverables — file layout

```
poc/demo/data-view/
  PLAN.md                (this file; leave untouched)
  serve-data-view.ps1    server: static + proxy + journal + vms + subjects
  README.md              operator doc (section 12)
  slides.html            the minimal deck (section 11)
  ui/
    actions.html         served at /            (actions window)
    actions.js
    data.html            served at /data        (data window)
    data.js
    shared.js            personas, call helpers, journal client, box registry
    shared.css           tokens + shared chrome for both windows
```

No other files. `slides.html` is self-contained (inline CSS/JS) like the
existing deck.

## 4. Server — `serve-data-view.ps1`

Copy-adapt from `poc/demo/by-act/serve-by-act.ps1` (do not dot-source it). Carry over
verbatim-in-behavior:

- `param` block: `-Port` (default **8092**), `-YurunaRoot`, `-CoreIp`,
  `-EdgeAIp`, `-EdgeBIp`, `-BindAddress` (default `localhost`; `any`/`*`/`+`
  = wildcard; a single hostname/IP binds that NIC **plus** localhost),
  `-SharePersonaPasswords`.
- Framework bootstrap: dot-source `../../../test/AmisAd.HostCommon.ps1`,
  `Resolve-YurunaRoot` (warn-and-degrade), `Initialize-AmisAdHost`
  (warn-and-degrade), forward-slash relative paths.
- `Resolve-VmIp` (driver `Get-VMIp` -> handoff `<name>.ip.txt` fallback).
- `Get-PersonaSecret` with the 11-user list and per-process cache.
- `Test-LoopbackClient` and the per-request vault-password gate on
  `/api/personas` (`<withheld: remote viewer>` for remote clients unless
  `-SharePersonaPasswords`).
- Listener prefix + wildcard handling, the Windows http.sys
  access-denied rethrow with the `netsh http add urlacl` hint, and the
  startup banner that enumerates reachable non-loopback URLs.
- `Invoke-Proxy` relaying upstream status verbatim (4xx from the lab is demo
  evidence), `Write-Body`/`Write-Json`, the `$mime` map, `Send-StaticFile`
  with the traversal guard and the `art/*` re-root.
- The synchronous single-threaded request loop with per-request try/catch ->
  500 JSON.

Changes and additions:

1. **HttpClient timeout 30 seconds** (not 60). The longest legitimate
   upstream call is a sealed-environment dispatch inside `POST /v1/needs`;
   30s covers it while halving the worst-case stall of the single-threaded
   loop when a VM is down.
2. **Static routing:** `''` -> `ui/actions.html`; `/data` -> `ui/data.html`;
   `/slides.html` -> `slides.html`; everything else falls through to the
   normal static resolver (`ui/...`, `art/...`).
3. **`GET /api/topology`** -- unchanged shape:
   `{ core, edgeA, edgeB }`.
4. **`GET /api/vms`** -- `[ { name, state, ip } ]` for `amisad-core`,
   `amisad-edge-a`, `amisad-edge-b`. `state` from the host driver's
   `Get-VMState` (contract values `absent|stopped|running|unknown`, portable
   across KVM/Hyper-V/UTM); guard with
   `Get-Command Get-VMState -ErrorAction SilentlyContinue` and report
   `unknown` when the driver is absent, exactly like `Resolve-VmIp` guards
   `Get-VMIp`. `ip` from the already-resolved `$CoreIp`/`$EdgeAIp`/
   `$EdgeBIp`. Cache the whole answer for 5 seconds (`$script:vmCache`,
   `$script:vmCacheAt`) -- `virsh domstate` per VM per poll is cheap but the
   KVM IP fallback chain is not, and the UI polls.
5. **`GET /api/subjects`** -- `{ maya: "<hash>", pat: "<hash>" }` where
   `<hash>` = lowercase hex SHA-256 of `"<actor>|person|subject"`, first 16
   chars -- the same derivation the coordinator uses for pseudonymous
   subjects. Compute in PowerShell
   (`[System.Security.Cryptography.SHA256]`); computing server-side avoids
   WebCrypto's secure-context restriction, which would break the data window
   on `http://<ip>:8092`. (Known-good check: `maya` -> `ab34d263a4173d0e`.)
6. **The journal** -- the synchronization bus between the two windows:
   - Server state: `$script:journal` (a `List[object]`), `$script:journalSeq`
     (int, starts 0).
   - `POST /api/journal` with body `{ kind, ... }` -> server stamps
     `seq = ++journalSeq` and `ts` (Unix ms via
     `[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()`), appends, returns
     `{ seq, ts }`.
   - `GET /api/journal?since=<n>` -> `{ latest: <journalSeq>, events: [ ... ] }`
     with every event whose `seq > n` (missing/invalid `since` = 0). Use
     `ConvertTo-Json -Depth 12` for journal responses (step events nest
     deeper than the default 8 the other routes keep).
   - `POST /api/journal/reset` -> clears the list (seq keeps counting up;
     never reuse a seq), returns `{ ok: true }`.
   - In-memory only; a server restart clears the timeline. Say so in
     README troubleshooting.
7. Banner additions: print both window URLs and the deck URL, e.g.
   `actions: http://localhost:8092/   data: http://localhost:8092/data
   slides: http://localhost:8092/slides.html`, plus the same remote-URL
   enumeration and firewall reminder as `serve-by-act.ps1`.

## 5. Journal event contract

Producers: the actions window (steps, resets, notes). Consumers: both
windows. Event kinds:

```jsonc
// kind: "step" -- one executed step
{
  "kind": "step",
  "step": {
    "id": "s001-02",              // stable: scenario + per-scenario ordinal
    "scenario": "s001",
    "persona": "maya",
    "label": "Submit the gift need",
    "status": "ok" | "fail" | "refused-pass",   // refused-pass = 4xx that IS the pass
    "note": "<verdict note>",
    "started_ms": 0,              // Unix ms
    "duration_ms": 0,
    "calls": [ { "method": "POST", "url": "core/30080/v1/needs", "status": 201 } ],
    "touches": [ "seller.orders", "ledger.verify" ],   // box ids, section 8
    "captured": { "s001_handle": "...", "s001_match": "..." }  // only keys set by this step
  }
}
// kind: "note" -- free annotation (consent preflight result, lab warnings)
{ "kind": "note", "text": "re-granted Maya's participation" }
// kind: "reset" -- emitted after POST /api/journal/reset by the resetting window
```

The data window folds `captured` across all events into its notebook (used
to instantiate templated boxes, section 7) and uses `touches` to fast-poll and
attribute flashes. Both windows poll `GET /api/journal?since=<last seen>`
every 1 second.

Consumer rules (both windows):

- **Server-restart detection:** if a poll's `latest` is *lower* than the
  client's cursor, the server restarted (in-memory journal, seq reset).
  Reset the cursor to 0, discard all journal-derived state (timeline fills,
  notebook fold, attributions, leak-scanner counters and latch), and
  rebuild from the events returned. Without this rule a restarted server
  leaves every open window silently frozen while polls keep returning 200.
- **Reset propagation:** on receiving `kind: "reset"`, every window
  discards all journal-derived state exactly as above; actions windows
  additionally clear their own `amisad-dv-state`/`amisad-dv-done`
  localStorage. The journal is the authoritative notebook source across
  machines; localStorage is only a boot-time seed used when the journal is
  empty (single-machine reload before any server restart).

## 6. Actions window — `/` (`ui/actions.html` + `actions.js`)

### 6.1 The step script

Port the `SCENARIOS` and `STEPS` arrays from `poc/demo/by-act/ui/app.js` **verbatim
in content** (same order, same personas, same labels, same explain texts,
same request bodies, same `capture`/`check`/`refusal`/`optional`/`needs`
semantics), with two mechanical changes:

1. **Stable ids:** `id: "s001-01" ... "s010-03"` -- scenario plus 1-based
   ordinal *within* the scenario (the old demo keys checkmarks off the
   global array index, which breaks on reorder).
2. **`touches`:** add the per-step box-id array from the table in section 8.

Preserve the old demo's execution semantics exactly:

- `verdictFor`: `step.check(results)` overrides everything; else `refusal`
  steps pass iff the **last** result's status is 400-499; else any status >=
  400 fails the step.
- `needs:` gating -- a step's Run button stays disabled until every listed
  notebook key is captured (`s004_envs` counts by array length).
- `token(actor)` mints a fresh identity token per step
  (`POST core/30084/v1/tokens`); include token-mint calls in the journal
  `calls` list.
- Boot-time `ensureBuyerConsents()` (read consent state via
  `POST core/30080/v1/consents/state`; re-grant only grants that read
  `revoked`), reported in the header *and* journaled as a `note` event.
- On every step completion: save notebook to localStorage **and** `POST
  /api/journal` the step event. Journal the failure path too
  (`status: "fail"` with the caught message in `note`).
- Produce the event's `captured` field by **snapshotting the notebook state
  object before `step.run()` and diffing after `capture()` completes** --
  several steps (s007-01, s009-03, s008-03) write state keys inside `run()`
  itself, so instrumenting `capture()` alone would silently miss them and
  strand the `connect.erp`-adjacent boxes and the s008 countdown.

### 6.2 The timeline (top half)

An EasyTimeline-style swimlane chart, rendered as DOM (no canvas):

- **Rows:** the 11 personas in `PERSONAS` declaration order (maya, elena,
  tom, marcel, kai, priya, ingrid, dana, alex, sam, pat), each row headed by
  the avatar initial-circle and name. Row heights fixed (~28px compact).
- **Columns:** one slot per step, in presentation order (SCENARIOS order:
  s001 s002 s003 - s005 s006 s007 s009 - s004 s008 s010; steps in STEPS
  order within each scenario -- 69 slots total). Group columns under
  scenario header cells (id + short name), and scenario groups under three
  act bands tinted with the act color. The chart lives in an
  `overflow-x: auto` container; two density toggles (compact 14px / wide
  28px slot width).
- **Cell states:** *ghost* (not yet run: dashed dot in the acting persona's
  lane -- the entire script is visible before the demo starts); *done*
  (filled bar in the act color); *refused-pass* (filled bar + shield glyph --
  a 4xx that proves a boundary held); *failed* (red); *current* (pulsing
  outline -- defined below). Optional steps get 60% opacity and an `(opt)`
  tooltip suffix.
- **Time:** each executed cell's tooltip shows `HH:MM:SS + duration`; a thin
  vertical "now" rule sits after the last executed slot. Auto-scroll keeps
  the current slot in view (suppressed while the operator is hovering the
  chart).
- **Interaction:** clicking any cell selects that step in the runner card
  below. **Run enablement is unchanged from the old demo:** any not-done
  step whose persona matches the selection and whose `needs:` keys are
  captured is runnable from the runner card, in any order; done and
  not-yet-runnable steps get read-only inspection. `current` is purely
  visual -- the first not-done non-optional step in presentation order
  (optional steps never hold the `current` marker).
  The timeline re-derives entirely from the journal -- a reload, or a second
  browser on another machine, reconstructs the same picture.

### 6.3 The runner (bottom half)

- Persona `<select>` (same 11 + overview), persona identity card with the
  vault password toggle (from `/api/personas`, honoring the withheld
  marker), topology chip, consent-preflight chip.
- **Current step card:** step number, persona chip (highlighted when it
  matches the selected persona -- only then is Run enabled), label, explain
  text, `needs:` missing-key warning, Run button, then per-call result rows
  (label + status pill + collapsible JSON) and the verdict line
  (`[OK]`/`[X]` + note) exactly like the old console.
- Notebook chips (captured ids, with the s008 disclosure-expiry countdown)
  and the rolling call log, as side panels.
- **Reset demo state** button: confirm dialog -> clear localStorage keys,
  `POST /api/journal/reset`, re-render. (The lab itself is untouched, as
  today.)

## 7. Data window — `/data` (`ui/data.html` + `data.js`)

### 7.1 Layout

- **Header:** title, topology chip, wall clock, and the **privacy strip**
  (section 7.4) -- always visible.
- **VM row:** three cards (`amisad-core`, `amisad-edge-a`, `amisad-edge-b`)
  from `/api/vms`: power state (green `running` / red otherwise), IP, and a
  per-service health dot-row (core: ten dots from `/health` of NodePorts
  30080-30089; edges: one dot from `/api/edge-x/health`). A proxy 502 on a
  health probe = red dot; the VM card shows the process picture of that VM.
- **Main grid:** boxes grouped by VM and service (core boxes in a 3-column
  grid; the two edge columns to the right). Every box: title, `service:port`
  chip, key->value rows, "changed HH:MM:SS - by <persona> -- <step label>"
  attribution line, and a stale badge when its last poll failed.
- **Mini-timeline:** above the footer, a compact read-only replica of the
  actions window's swimlane chart -- the same 11 lanes x 69 slots rendered
  from the same journal fold and shared renderer config, at ~8px slot
  width with persona initials for lane labels and no interactivity. It
  exists so a single projector showing `/data` still carries the
  parallel-persona picture the slides point at; it must stay under ~120px
  tall and auto-scroll with the current slot.
- **Footer ticker:** the last ~8 journal events and any poll errors.

### 7.2 The box registry (in `shared.js`)

Every box below names its **single source endpoint** (all GET, all through
the `/api/` proxy) and its poll **tier**: `fast` = every sweep, `slow` =
every 3rd sweep, `lazy` = only once its templated id exists in the notebook.
One sequential poll pump (section 7.3) serves them all.

| box id | source (GET) | shows | tier |
|---|---|---|---|
| `coordinator.contributions` | `core/30080/v1/needs/contributions` | open needs contributing to aggregation (count) | slow^1 |
| `ledger.verify` | `core/30081/v1/verify` | attestation/settlement/consent chain lengths + ok flags | fast |
| `ledger.consent.maya` | `core/30081/v1/consents/subject/<maya-hash>` | participation / contribution / history length for the pseudonym from `/api/subjects` | fast |
| `ledger.settlement.last` | `core/30081/v1/settlements/match/<id>` | value, confirmed, net total, entry count -- `<id>` = most recently captured `*_match` key | lazy |
| `seller.orders` | `core/30083/v1/orders` | order count + tally by state (committed/provisioning/fulfilled/settled) | fast |
| `seller.catalog.a` | `core/30083/v1/offers/region/region-a` | matchable offer count, region-a | fast |
| `seller.catalog.b` | `core/30083/v1/offers/region/region-b` | matchable offer count, region-b | slow |
| `resource.edges` | `core/30082/v1/edges` | registered edge fleet: region -> endpoint, capacity | fast |
| `resource.telemetry` | `core/30082/v1/telemetry` | lifecycle event count by kind (incl. aborted) | fast |
| `resource.incidents` | `core/30082/v1/incidents` | operator incident queue length | fast |
| `insights.workbench` | `core/30085/v1/workbench` | above-threshold cells (category/region -> needs); suppressed cells are *absent* -- label the box accordingly | fast |
| `insights.aggregates` | `core/30085/v1/aggregates` | aggregation cycles recorded + last contributions figure | slow |
| `insights.unmet` | `core/30085/v1/unmet-demand` | unmet-demand flags | slow |
| `platform.incidents` | `core/30086/v1/incidents` | cross-party incident case count | fast |
| `platform.disclosure` | `core/30086/v1/support/cases/<s008_case>/disclosure` | HTTP status is the display: 404 not requested / 200 + expiry countdown / **410 expired**. The countdown value comes from the folded `s008_expiry` notebook key (journaled by s008-03), **not** from the response body -- the 200 body is `{ artifact }` only; while the key is present and unexpired, show `<n>s left` beside the 200 | lazy |
| `ads.briefs` | `core/30087/v1/briefs` | open creative briefs | fast |
| `ads.campaign` | `core/30087/v1/campaigns/<s005_campaign>` | status + `budget remaining / committed per match` pacing | lazy |
| `ads.attributions` | `core/30087/v1/attributions` | attribution count + aggregate credit | fast |
| `connect.deltas` | `core/30088/v1/deltas` | inventory deltas applied from the ERP | fast |
| `connect.audit` | `core/30088/v1/audit` | **refused** out-of-scope call count | fast |
| `connect.erp` | `core/30088/v1/erp/orders/<s007_match>` | ERP mirror state for the s007 order | lazy |
| `audit.accesslog` | `core/30089/v1/access-log` | auditor read count + "all GET" boolean computed client-side | fast |
| `identity.presence` | `core/30084/health` | up/down only, with the fixed caption "knows the login -- by design; nothing downstream does" (issued tokens are deliberately unlistable) | slow |
| `edge-a.runtime` | `edge-a/health` + `edge-a/version` | slice-runtime up + version | fast |
| `edge-a.egress` | `edge-a/v1/egress` | records that **left** sealed environments (attestations, telemetry, settlement instructions, match/shortlist records -- the latter carry the buyer's chosen context line): count + last entry kind | fast |
| `edge-a.ingress` | `edge-a/v1/ingress` | what the **ad economy sends in**: campaign creatives placed inside the seal (populated only by the boosted-shortlist path, s005) -- caption it so; the buyer's envelope is deliberately never logged here | fast |
| `edge-b.runtime` / `edge-b.egress` / `edge-b.ingress` | same, `edge-b/...` | same | slow^2 |

^1 `GET /v1/needs/contributions` fans out one ledger consent lookup per open
need on every call -- real but bounded load; the slow tier keeps it honest
without hammering.
^2 edge-b receives **no environment traffic in this script** (every need is
jurisdiction region-a, and s004 pins placement there; the unrestricted
placement answer in s004-02 is compute-only -- `resource-svc`'s `place()`
mutates nothing). Keep `edge-b.*` permanently at slow tier and caption the
cards so the emptiness is the point: *"registered, standing by -- sovereignty
means this jurisdiction's traffic never arrives here."*

**Deliberately absent** (the services hide them; the box grid must not fake
them -- and say so in README): coordinator open-need contents/handles,
shortlists, held over-cap approvals, mandate scopes (only the consent-chain
*events* show), connect partners/credentials, insights below-threshold
cells, seller stock numbers, identity token list. Where a box borders on
hidden state (e.g. `ledger.consent.maya` showing mandate grant/revoke
events while scopes stay private), the box caption states what is *not*
visible -- invisibility is the feature.

### 7.3 The poll pump

One sequential loop (never concurrent lab requests -- the server is
single-threaded and the actions window's slow POSTs share it; the 1-second
`/api/journal` poll is the single stated exception to the no-concurrency
rule, and `/api/vms` plus the twelve VM-card health probes ride the pump at
`slow` tier):

- Maintain a queue of due boxes (tier cadence: sweep ~ every 4s for `fast`,
  every 12s for `slow`; `lazy` boxes join `fast` once instantiable). Issue
  **one** fetch at a time with ~150ms spacing; a full fast sweep is ~3-4s at
  baseline, ~5s once all lazy boxes are promoted -- both acceptable.
- On each journal `step` event: immediately enqueue that step's `touches`
  at the queue head (fast-poll), and stamp the attribution line of those
  boxes with the step's persona + label when their value actually changes.
- Change detection: deep-compare the *displayed projection* (not the raw
  body) against the previous poll; on change, flash the box (terracotta
  fade ~1.6s, `prefers-reduced-motion` disables) and show a `+n` delta
  badge on counter rows.
- Failures mark the box stale (gray badge with the HTTP/transport error) and
  never clear the last good values.
- The data window issues **no** journal writes and **no** lab POSTs, ever.

### 7.4 The privacy strip

The centerpiece. What the code actually guarantees -- verified against
`slice-runtime`, `seller-svc`, and the coordinator -- is: *the buyer's
identity appears nowhere; the only buyer content that travels is the
one-line context summary she chose to share* (`need_context`, which the
slice-runtime deliberately includes in match/shortlist records as the
buyer-chosen shareable summary, and which the seller's order board then
carries). The strip states exactly that, in three permanent cells:

1. **"Maya on the wire"** -- her pseudonymous subject hash from
   `/api/subjects` with the derivation caption
   (`sha256("maya|person|subject")[:16]` -- the ledger, the coordinator, and
   every box on this screen know her only as this).
2. **"Her identity: zero, anywhere"** -- a live leak scanner over every
   response body the pump receives from the lab (core NodePorts *and* both
   edges). It scans for buyer-identity markers only, whole-word
   (`\b...\b` regex, case-insensitive): the buyer-side logins `maya` and
   `pat`, plus PII field names that must never exist (`"name"`,
   `"address"`, `"email"`, `"phone"` as JSON keys). Display
   `0 hits - N responses - M KB scanned` (green); a hit flips the cell red
   with box id + marker and stays latched until demo reset. Supply-side
   names are **excluded by design and captioned so** (`elena-atelier` is a
   public tenant id, `kai` a public creator credit -- catalog data, not
   buyer data; whole-word matching also keeps `pat` from false-firing on
   `participation`). The scan covers only lab traffic -- never
   `/api/personas` (vault, host-side by design) or `/api/journal` (UI
   labels legitimately name personas). This cell staying green for 30
   minutes is machine-checked truth; if it ever goes red, that is a real
   finding -- surface it, never mask it.
3. **"What she chose to share"** -- a second scanner counts lab responses
   containing her context markers (`wedding`, `anniversary`,
   `warm-weather`, `office` -- the words of the demo's `need_context`
   lines). These DO travel -- to the seller's order board and the egress
   log -- *by design*: the context line is the buyer-authored, shareable
   half of the envelope. Display `her words: <n> places - her name: 0`
   (neutral/green), with the caption "the seller reads *'Wedding gift from
   the couple's wish list...'* and a pseudonymous handle -- never who". The
   contrast between cells 2 and 3 is the demo's thesis, stated by a
   machine: identity zero, shared context only where she sent it.

The sealed-side story needs no ingress scan: the slice-runtime's ingress
log is deliberately buyer-signal-free (it records only campaign creatives
entering the seal, s005's boosted-shortlist path). The envelope's private
half (budget, deadline, constraints) exists only in flight and inside the
environment, and is never logged anywhere -- which is why no box can show
it, and the `edge-a.ingress` box caption says so.

## 8. Step → touches table

The authoritative mapping from executed step to flashed boxes. `[]` = pure
read (timeline shows the bar; no box flashes). Steps are listed as
`scenario-ordinal` matching section 6.1 ids, in presentation order.

| step | label (abbrev.) | touches |
|---|---|---|
| s001-01 | Publish standing offer | `seller.catalog.a` |
| s001-02 | Submit the gift need | `seller.orders` `ledger.verify` `resource.telemetry` `edge-a.egress` `ledger.settlement.last` |
| s001-03 | Ship it (provisioning) | `seller.orders` |
| s001-04 | Fulfilled -> settled | `seller.orders` `ledger.verify` `ledger.settlement.last` |
| s001-05 | Check delivery | [] |
| s001-06 | Receipt is a hash chain | [] |
| s002-01 | Publish the dress rack | `seller.catalog.a` `seller.catalog.b` |
| s002-02 | Ask for the shortlist | `ledger.verify` `resource.telemetry` `edge-a.egress` |
| s002-03 | Book the Thursday fitting | `seller.orders` |
| s002-04 | Notifications: exactly two | [] |
| s002-05 | Fulfill the fitting order (opt) | `seller.orders` `ledger.verify` `ledger.settlement.last` |
| s003-01 | Sign up (consent grants) | `ledger.consent.maya` `ledger.verify` |
| s003-02 | Open a need nothing fits | `coordinator.contributions` `ledger.verify` `resource.telemetry` `edge-a.egress` |
| s003-03 | Pause participation | `ledger.consent.maya` `ledger.verify` |
| s003-04 | Publish a PERFECT offer | `seller.catalog.a` |
| s003-05 | ...silence | [] |
| s003-06 | Resume -- served immediately | `ledger.consent.maya` `ledger.verify` `seller.orders` `coordinator.contributions` `resource.telemetry` `edge-a.egress` |
| s003-07 | Consent history | [] |
| s005-01 | Create the campaign | `ads.campaign` |
| s005-02 | Send the creative brief | `ads.briefs` |
| s005-03 | Check the demand queue | [] |
| s005-04 | Deliver the asset | [] *(assets are hidden state until activation links them)* |
| s005-05 | Activate the campaign | `ads.campaign` |
| s005-06 | Publish the summer offer | `seller.catalog.a` |
| s005-07 | State the summer need | `ledger.verify` `resource.telemetry` `edge-a.ingress` `edge-a.egress` |
| s005-08 | Accept the boosted offer | `seller.orders` |
| s005-09 | Fulfill the order | `seller.orders` `ledger.verify` `ledger.settlement.last` `ads.attributions` `ads.campaign` |
| s005-10 | The five-way split | [] |
| s005-11 | Performance view | [] |
| s006-01 | Publish household offers | `seller.catalog.a` |
| s006-02 | Grant Pat a scoped mandate | `ledger.consent.maya` `ledger.verify` |
| s006-03 | Open the delegate workspace | [] |
| s006-04 | Buy under the cap | `seller.orders` `ledger.verify` `resource.telemetry` `edge-a.egress` |
| s006-05 | Try the premium vase (over cap) | `ledger.verify` `resource.telemetry` `edge-a.egress` |
| s006-06 | Approve the held closing | `seller.orders` |
| s006-07 | Her activity trail | [] |
| s006-08 | Try out of scope (opt, refusal) | [] |
| s006-09 | Revoke the mandate (opt) | `ledger.consent.maya` `ledger.verify` |
| s007-01 | Register + certify connector | [] *(partners are hidden state -- say so live)* |
| s007-02 | Grant scoped credentials | [] *(hidden)* |
| s007-03 | Sync the ERP catalog | `seller.catalog.a` |
| s007-04 | Stockroom sells the last lamp | `seller.catalog.a` `connect.deltas` |
| s007-05 | Need a lamp | `seller.orders` `ledger.verify` `resource.telemetry` `edge-a.egress` `connect.erp` |
| s007-06 | The ERP mirror agrees | [] |
| s007-07 | Out-of-scope query (opt, refusal) | `connect.audit` |
| s009-01 | Record the week's demand | `insights.workbench` `insights.unmet` |
| s009-02 | The workbench suppresses | [] |
| s009-03 | Publish the outlook | [] |
| s009-04 | Elena's outlook (opt) | [] |
| s009-05 | Marcel's view (opt) | [] |
| s004-01 | Register both regions | `resource.edges` |
| s004-02 | Unrestricted placement -> b | [] *(see verify note below)* |
| s004-03 | Pin sovereignty -> region-a | [] |
| s004-04 | Publish the ceramics offer | `seller.catalog.a` |
| s004-05 | Arm two isolation faults | [] *(armed count is hidden state)* |
| s004-06 | Submit the ceramics need | `resource.incidents` `resource.telemetry` `ledger.verify` `seller.orders` `edge-a.egress` |
| s004-07 | The incident queue | [] |
| s004-08 | Aborted env attestation | [] |
| s004-09 | Escalate the pattern | `platform.incidents` |
| s004-10 | The cross-party case | [] |
| s008-01 | Open the case (metadata) | `platform.disclosure` |
| s008-02 | Request a disclosure | `platform.disclosure` |
| s008-03 | Grant it -- time-boxed | `ledger.consent.maya` `ledger.verify` `platform.disclosure` |
| s008-04 | Read what was granted | [] |
| s008-05 | Post the refund | `ledger.verify` `ledger.settlement.last` |
| s008-06 | After expiry: 410 (refusal) | `platform.disclosure` |
| s010-01 | Certify the evidence trail | `audit.accesslog` |
| s010-02 | Tamper -- get caught | [] *(the tamper check recomputes hashes over the submitted dump only; the auditor's ledger reads happen in s010-01)* |
| s010-03 | The auditor's access log | [] |

Facts this table already encodes (verified in source; do not re-litigate
while porting): `POST /v1/placements` is compute-only -- `place()` filters
and ranks the edge fleet without reserving capacity, so s004-02/-03
correctly touch nothing; a **no-fit** matching attempt still creates,
attests, and destroys a sealed environment (4 attestation entries, 4
mirrored telemetry posts, 8 egress log entries), which is why s003-02
touches `ledger.verify`, `resource.telemetry`, and `edge-a.egress`; the
ingress log is written only by the boosted-shortlist path, so
`edge-a.ingress` appears exactly once, at s005-07. Flash-hints that miss
are harmless (the regular sweep catches real changes within ~4s), but the
table is authoritative -- do not add speculative touches.

## 9. Synchronization & multi-machine

- Both windows poll the journal each second; the actions window is the only
  writer. Any number of viewers can open `/` or `/data` on any machine that
  can reach the port (with `-BindAddress any`); they all reconstruct the
  same timeline and see the same flashes.
- Reload-safe: timeline and notebook rebuild from the journal; box values
  rebuild from the next sweep.
- The recommended stage setup (put in README): projector shows `/data` --
  which carries the box grid, the privacy strip, *and* the mini-timeline,
  so the audience always sees both pictures; presenter's laptop shows `/`
  (actions) on one half and `/slides.html` on the other, notes toggled on.
  With two displays, project `/data` and `/` side by side and the
  mini-timeline becomes redundant headroom.

## 10. What changes vs. `poc/demo/by-act` (for the README's "which demo when")

`poc/demo/by-act` remains the button-per-scenario console; this demo adds the
machine's own view and the parallel-persona picture. Neither replaces the
other; they must not run on the same port and must not be open against the
same lab *simultaneously during a presentation* (double consent-preflights
and duplicate `demo-` upserts are harmless but muddy the timeline).

## 11. The deck — `slides.html`

Self-contained single file. Carry over from `poc/demo/by-act/slides.html`: the vh
typography scale, navy/terracotta/paper tokens, divider styling (+
`body.on-divider` edge-strip inversion), edge strips, keys
(N/->/PageDown/Space next; P/<-/PageUp/Backspace prev; Home/End; S notes;
modifier chords ignored), hash-per-slide history (pushState; popstate +
hashchange resync), HUD pill, click-to-advance with `.edge`/`.notes`/link
exclusions, `prefers-reduced-motion`. Do not copy slide content -- the deck
is new, **18 slides**:

Bullet rule enforced by construction: every slide body is at most **3
bullets**, each at most **5 words**. Scene slides additionally get one
small-type *stage-direction caption* (not a bullet) naming what to watch,
formatted `watch: <window> -- <box/lane>`. Presenter notes carry the
narration and the exact Run-button sequence (adapt the cue content from the
old deck's notes; keep operator cues like persona-switch announcements and
the s008 countdown talk-over).

| # | kind | title | bullets | stage direction / note anchor |
|---|---|---|---|---|
| 1 | divider | AmisAd | Buyer served, seller found - Network rewarded, platform credited - Not one secret spent | notes: pre-flight checklist -- server running, three surfaces open, journal reset, identity cell green-zero |
| 2 | content | The promise | Nothing about her leaves - Matched in sealed environments - Silence when nothing fits | notes: the only pure-narrative minute |
| 3 | content | How to read the room | Left: the people - Right: the machine - Everything live, nothing staged | watch: data -- VM cards green; privacy strip: identity 0, her words 0 (so far) |
| 4 | content | Eleven people, one loop | Eleven personas, one loop - Three trust-boundary roles - One auditor reads everything | watch: data -- mini-timeline: eleven empty lanes, the whole script in ghost |
| 5 | divider | Act I -- The Buyer Loop | A gift closes itself - A dress she chooses - A switch silences everything | |
| 6 | scene s001 | The gift | Need travels sealed - Match, ship, delivered - Elena never sees Maya | watch: data -- seller.orders, ledger chains grow, egress counts; identity cell stays 0 while "her words" ticks to 1 -- her chosen context reached the seller, her name reached no one |
| 7 | scene s002 | The dress | Five dresses, one fits - Nothing commits until booked - Two notifications, ever | watch: data -- catalog-a holds the four in-region dresses (the fifth is out-of-region -- the point); orders unchanged until booking |
| 8 | scene s003 | The kill switch | Consent gates the match - Perfect offer: silence - Resume: served immediately | watch: data -- consent box flips revoked; contributions count; then everything moves at once |
| 9 | divider | Act II -- The Economy | Ads, delegation, integration, analytics - Rebuilt without surveillance | |
| 10 | scene s005 | The campaign | Aggregates, never individuals - Boost happens inside seal - Five-way split on close | watch: data -- campaign budget ticks down; ingress carries the creative in |
| 11 | scene s006 | The delegate | Mandate: category, cap, expiry - Under cap: Pat closes - Over cap: Maya approves | watch: data -- mini-timeline: Pat's lane fills between Maya's; consent chain +mandate |
| 12 | scene s007 | The stockroom | The ERP is truth - Sold out vanishes silently - Out of scope: refused | watch: data -- the lamp is gone from the matchable catalog; refused-calls log +1 *(needs s007-07 -- the one optional step to keep; skip other optionals first)* |
| 13 | scene s009 | The forecast | Above the anonymity threshold - Below it: absent - One outlook, identical everywhere | watch: data -- workbench shows region-a only |
| 14 | divider | Act III -- Trust & Operations | A slice fails safe - A dispute resolved blind - An auditor trusts no one | |
| 15 | scene s004 | The sovereign slice | Policy pins the region - Faults abort before opening - Exactly one settlement | watch: data -- incidents +2, telemetry aborts, then one clean settlement; notes: point at the still-empty edge-b column -- sovereignty means nothing ever arrived there |
| 16 | scene s008 | The dispute | Support sees metadata only - Disclosure consented, time-boxed - Refund never edits history | watch: data -- disclosure box 200 -> countdown -> **410** |
| 17 | scene s010 | The audit | Recomputed from raw dumps - Tamper caught, localized - Auditor only ever read | watch: data -- access log: every entry GET |
| 18 | close | Not one secret spent | Buyer served, seller found - Nobody ever saw anyone - Verify it yourself | notes: Q&A pivots -- point back at the privacy strip (identity 0 all session) and the filled mini-timeline |

## 12. README.md

Sections: what this demo is (two windows + deck, one server); prerequisites
(green end-to-end run, VMs still up, Yuruna checkout for vault passwords --
same as `poc/demo/by-act`); start (`pwsh poc/demo/data-view/serve-data-view.ps1`,
`-BindAddress any` for presenting from another machine, firewall + Windows
urlacl notes); the three URLs; stage setup (section 9); the 30-minute budget table
below; "what the boxes can and cannot show" (the hidden-state list from
section 7.2 -- invisibility as feature); troubleshooting (core IP unresolved; 502s;
journal cleared by server restart -- open windows detect this and rebuild,
per section 5; the buyer-403 consent preflight; data-window staleness when the lab
is down; both-demos-open caveat from section 10). Add a **rehearsal note**: the
lab's durable state means delta moments differ between a first run and a
re-run (offers upsert; `demo-erp-lamp-01`'s stock stays zeroed in
seller-svc memory until the pod restarts), which is why the slide stage
directions are phrased as *states*, not deltas -- rehearse on the same lab
freely, and restore the lab snapshot only if the count-drop moments matter.

| Segment | Scenes | Budget |
|---|---|---|
| Intro (slides 1-4) | windows tour, cast | 3 min |
| Act I | s001 3' - s002 2.5' - s003 3' | 9 min |
| Act II | s005 3.5' - s006 2' - s007 1.5' - s009 1' | 8 min |
| Act III | s004 3.5' - s008 2.5' - s010 2' | 8 min |
| Close (slide 18) | the strip, the timeline | 2 min |

Optional steps remain the schedule buffer.

## 13. Verification (run all; report results honestly)

1. `Invoke-ScriptAnalyzer poc/demo/data-view/serve-data-view.ps1` -- no new
   rule/severity classes beyond the `serve-by-act.ps1` baseline.
2. `node --check` on `ui/actions.js`, `ui/data.js`, `ui/shared.js`; open
   `slides.html`'s inline script through `node --check` on an extracted
   copy in the scratchpad.
3. Server smoke (lab up): start on 8092 with the real core IP; then
   `curl` each: `/` , `/data`, `/slides.html`, `/ui/shared.js`,
   `/art/icon.svg` -> 200; `/api/topology`, `/api/vms` (3 entries, states),
   `/api/subjects` (maya = `ab34d263a4173d0e`); journal roundtrip: POST an
   event -> `GET ?since=0` returns it, `?since=<seq>` returns empty; reset
   clears.
4. Proxy: `/api/core/30081/v1/verify` -> 200; `/api/edge-a/health` -> 200.
5. End-to-end slice: from the actions window run s001 complete; confirm
   the journal carries 6 step events, the timeline (and the data window's
   mini-timeline) fills Maya's and Elena's lanes, and in a second browser
   window `/data` flashes `seller.orders`, `ledger.verify`,
   `edge-a.egress` with attribution. Privacy strip after s001: identity
   cell green at `0 hits`, "her words" cell >= 1 (the wedding context line
   on the seller's order and in egress), `edge-a.ingress` count **0**
   (ingress first moves at s005-07, and only then).
6. Restart resilience: kill and restart the server mid-session; within ~2s
   every open window detects the cursor regression, resets, and resumes
   rendering new events (no silently-frozen windows).
7. Refusal path: run s006 through s006-08 (out-of-scope) -- shield glyph in
   Pat's lane, `refused-pass` in the journal.
8. Remote path: restart with `-BindAddress any`; from the LAN IP: both
   windows load, `/api/personas` returns withheld passwords, journal sync
   still works across two machines.
9. `git -C /home/ytest/git/amisad.dev status --short` shows only
   `poc/demo/data-view/` additions. Do not commit.
10. Stop any server processes started for testing; leave the operator's own
    servers untouched.

## 14. Resolved during implementation

Operator decisions taken before building:

- **Theme:** dark, control-room data window; light action window (the
  presenter's driving surface stays high-contrast in a lit room).
- **Browser floor:** Safari 13.1 / iPadOS 13. No flexbox `gap` (grid-gap and
  margins only), no `:is()`/`:where()`/`:has()`, no container queries, no
  `structuredClone`/`Array.at`/`replaceAll`.
- **Reset demo:** one button in *both* window headers; one confirm; clears
  journal-derived state everywhere **and** re-arms the buyer's participation
  consent. Lab records untouched.
- **Touch:** the demo can be driven from a tablet -- >=44px targets, tappable
  timeline slots (tapping another persona's slot switches to them), swipe
  navigation on the deck.

Payload shapes corrected against the running lab while wiring the boxes (the
services differ from the obvious guess; these are the verified names):
`resource-svc /v1/telemetry` -> `entries[].event`; `insights /v1/aggregates` ->
`cycles` + `latest_contributions` (not a list); `platform /v1/incidents` ->
`cases`; `ads /v1/attributions` -> `closed_matches` +
`agency_cents_total` + `creator_cents_total`; `ads /v1/campaigns/{id}` ->
`state` + `budget_cents` - `spent_cents` (no `budget_remaining_cents`);
slice-runtime `/v1/egress` and `/v1/ingress` -> `entries` (egress entries are
`"<kind>:{...}"` strings).

## 15. Out of scope (do not build)

- No new endpoints on any service; no SSH from the demo server into VMs
  (the health probes through the proxy are the process view -- an SSH
  channel would be write-capable and prove less about reachability).
- No historical persistence of the journal across server restarts.
- No editing of `poc/demo/by-act` (including its README).
- No screenshot/recording tooling.
