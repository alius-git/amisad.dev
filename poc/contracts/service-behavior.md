# Service behavior and recovery

The POC services share a small HTTP server. Aggregate request lines and headers
are limited to 32 KiB, bodies to 1 MiB, and the whole request read to 20 seconds.
Oversized requests return 413, malformed framing returns 400, and an expired read
returns 408. Duplicate Content-Length and Transfer-Encoding are rejected. Bodies
must be UTF-8. JSON allows at most 64 nested containers and rejects duplicate keys,
unescaped control characters, invalid surrogate escapes, leading-zero integers,
and incomplete fractions/exponents. Invalid JSON uses the localized `invalid_request`
problem response. Responses have a five-second write timeout.

Each connection is read and answered on its own thread, at most 32 at a time;
further connections wait in the listen backlog. `/health` and `/version` answer
without the service state, so they respond while a handler runs or a client
stalls mid-request. Every other request starts its handler only after it has
fully arrived, and each service runs one handler at a time under its state lock,
so service state keeps a single writer. Handlers see every request header in
arrival order and look names up ignoring ASCII case. After SIGTERM, running
handlers finish and answer, and requests that have not started answer 503
`service_stopping`. A handler panic exits the process with status 101.

`/health` answers 503 `service_stalled` once the running handler has gone 120
seconds without starting or finishing an outbound call through the shared client;
a handler that makes no call counts from its start. Only the handler's own calls
count as progress. Calls from other threads, such as slice-runtime's lease
renewal or seller-svc's event resends, do not, so they cannot hide a wedged
handler. One outbound call against a peer that answers takes at most about 52
seconds, so the limit is aimed at a handler wedged outside those bounds, such as
one blocked in a database call on a half-open connection. It fires for any
handler that spends 120 seconds without an outbound call, however, including
one busy with a slow database statement. The charts' liveness probe reads
`/health`, so Kubernetes then restarts the service.

## Ownership and retries

- Connector catalog and inventory calls use the tenant attached to the authorized
  credential. Catalog batches with a different tenant are rejected before forwarding.
  Seller offer ownership cannot be changed by an upsert, including at the SQL boundary.
  Seller inventory updates require `tenant` as well as `offer_id` and `stock`.
  `delta_ts` is a nonnegative monotonic source version (omission means legacy version
  zero). Older versions and equal-version/different-stock updates return 409
  `inventory_conflict`; identical replays return 200. Connector forwarding preserves
  the version. With `DATABASE_URL`, stock and version commit atomically in
  `seller.inventory` and reload after restart. Apply the additive `db/schema.sql`
  migration before restarting an existing seller deployment.
  Seller's direct API remains an internal lab interface; this does not add authentication
  to every internal service endpoint.
- An instruction replay with identical match ID, value, and splits returns 200;
  conflicting contents return 409. Order creation behaves the same way for the
  match ID, offer, tenant, need context, and appointment. A new write returns 201.
- Manual booking retains its deterministic match ID. Retrying after failure between
  the instruction and order resumes these writes. A completed identical booking
  returns 200 without another notification or attribution. A different selection
  on that completed handle returns 409. Shortlists and completed response caches
  remain in memory; coordinator restart still loses those handles. Instructions
  and orders survive restart when their services use `DATABASE_URL`.
- A delegated approval stays held until its commit succeeds. A failed commit
  answers 502 or 503 and keeps the hold, so the principal can approve again:
  each attempt records one mandate use, and the retry resumes the settlement
  instruction and order writes, whose identical replays answer 200. A committed
  approval leaves the held list, so approving it again answers 404
  `held_match_not_found`; revoking the mandate drops its holds. Holds stay in
  memory, like shortlists. Every delegated need is dispatched with policy
  `manual`, so the environment returns a shortlist and the coordinator decides
  commit or hold against the mandate cap. A match record that comes back anyway
  answers 502 `manual_dispatch_ignored` with no consent use or order recorded,
  which leaves the environment's own instruction for the auditor to report as
  unbacked. Approving a held match whose mandate no longer covers it -- the
  mandate expired, or was re-granted for another category -- answers 403
  `mandate_not_valid` with no mandate use, instruction or order recorded, and
  the match stays held; the cap is not re-checked, since approving an over-cap
  match is the approval's purpose. The approval executes under the mandate, so
  one the mandate no longer covers would record a mandate use the auditor
  counts as a violation; the scope is checked as on the under-cap resume, and
  a repeat answers the same refusal. An under-cap delegated commit that fails
  part-way answers 502 or 503 and stays pending for the same need: the same
  opaque envelope for the same jurisdiction, stated by the same delegate for
  the same principal. The delegate's retry of that need resumes it with the
  same environment, offer and match ID instead of a new dispatch, recording
  one more mandate use while the instruction and order replay with 200; a
  committed need leaves nothing pending, so stating it again is a new
  purchase. The retry passes the mandate check first, so an expired mandate
  refuses it, and a pending commit the current mandate's cap or scope no
  longer covers is dropped and the need dispatched anew. Revoking the mandate
  drops its pending commits, as it drops holds, so a re-grant dispatches the
  need anew. A seller that refuses the order outright (a 4xx, such as 409 or
  400 for an offer it no longer knows) leaves nothing pending either, so the
  next statement of the need dispatches anew; a 5xx or a lost connection keeps
  the commit pending. A dropped commit's settlement instruction stays without
  its order. Pending commits stay in memory, like holds.
- Fulfillment advances an order to `settled` only after ledger confirmation.
  Confirmation failure returns 503 without advancing the order. Repeating the
  confirmation is safe, including after service restart or an ambiguous response.
  Previously stranded `fulfilled` rows can be retried through the same endpoint.
- A full refund is identified by match and case. The adjustment entries themselves
  are its durable replay record, committed together. An identical replay returns
  200 with the previous outcome and appends nothing. A different case, case reuse
  for another match, or inconsistent prior compensation returns 409. Historical
  duplicate refunds are never silently deleted or repaired.
- Every ledger append needs the write token when ledger-svc has one: a POST
  without `Authorization: Bearer <LEDGER_WRITE_TOKEN>`, or with another value,
  answers 401 `write_token_required` and appends nothing; reads never need it.
  fabric-coordinator, seller-svc, platform-svc and slice-runtime send it on their
  ledger POSTs whenever they were started with it; slice-runtime started without
  it says so once on stderr. Sam's refund goes through platform-svc:
  `POST /v1/support/cases/refund` with a `case_id` answers 404 for
  an unknown case, otherwise posts the adjustment for the case's own match (a
  `match_id` in the body is ignored) and relays the ledger's status and body, so
  an identical replay answers 200 with the prior outcome. That route, case
  creation, the disclosure request and resolution need Sam's identity-mock
  token (`token` in the body): platform-svc verifies it with identity-mock and
  answers 401 `unverified_actor` when identity does not accept it and 403
  `support_agent_required` for another actor, before any change or ledger call;
  an unreachable identity-mock answers 503 `upstream_unavailable` and an
  unreadable answer 502 `upstream_failed`, also before any change. A route
  that names an unknown case answers 404 first; case reads stay open. The
  check binds a write to the actor `sam`, not to an authenticated person:
  identity-mock mints a token for any actor named in `POST /v1/tokens` with no
  credential, so a caller who reaches identity-mock can obtain Sam's token.
  The coordinator's delivery of a disclosure grant
  (`POST /v1/support/cases/disclosure/grant`) needs the write token instead:
  when platform-svc has one, a delivery without
  `Authorization: Bearer <LEDGER_WRITE_TOKEN>`, or with another value, answers
  401 `grant_token_required` and changes nothing; without one it stays open.
  fabric-coordinator sends it on that delivery whenever it was started with it.
- Audit certification requires a well-formed chain envelope, every row's payload
  and hashes, and a matching head. Explicit empty chains with the genesis head are
  accepted; missing evidence returns 502. Each environment must contain exactly
  `created`, `attested`, `executed` or `aborted`, then `destroyed`, in that order.
  Auditing compares settlement rows with the read-only instruction inventory:
  unique parties and exact amounts must match the confirmed instruction; a refund
  must negate every original party exactly once under one unique case. Orphan,
  duplicate, partial, excessive, or contradictory monetary evidence fails certification.
  Lifecycle rows are grouped in one pass.

## Consent chain

ledger-svc keeps one immutable consent chain for four grant types:
`participation` and `contribution` are the buyer's own consents (s003.silence),
`mandate` is a delegated-authority grant (s006.mandate), and `disclosure` is a
scoped, time-boxed support-case grant (s008.mediation). All four fold the same
way: the newest `grant` or `revoke` entry for a subject and grant type makes it
`granted` or `revoked`, and a subject with no entry reads `none`, which leaves
the default policy to the coordinator; the ledger only reports facts. A `use`
entry is the coordinator's execution-time record that a consent was relied on,
for a match or a disclosure delivery. It never changes the folded state, and
its chain position is what the auditor checks against the grants and revokes
before it (s010.certification).

## Localized problem messages

New problem responses carry a stable `code` and localized `error`. Clients branch
on HTTP status and `code`, never on translated text. `Accept-Language` selects
`en-US`, `pt-BR`, `zh-CN`, or `he-IL`, honoring positive quality weights and language
fallbacks. Unsupported languages fall back to English. `AMISAD_LOCALE` selects the
process default when no request language is supplied. Protocol keys, IDs, route
names, and order states remain unchanged. JSON is UTF-8, including Hebrew text;
consuming UIs are responsible for text direction and bidi isolation around IDs.

Every response carries `X-Request-Id`. A caller's value of 1 to 64 letters,
digits, `.`, `_` or `-` is kept; anything else, or no value, is replaced by a
minted 16-character hexadecimal ID. Calls a handler makes to other services
forward it, error bodies that are JSON objects repeat it as `correlation_id`,
and each 5xx answer writes one stderr line naming the service, status, code,
method, path and ID. The ID never enters a ledger row or the edge egress log.
`Response::problem_detail` adds `detail`, an untranslated developer diagnostic;
localization replaces only a catalog problem's `error` text and keeps every
other member.

Catalogs live in `components/lib/amisad-common/locales/` and are embedded by Cargo
and Bazel. Non-English entries are machine-generated drafts with English source
hashes and provenance; they await linguistic review. `test/check_messages.py`
rejects missing, unused, empty, or stale entries. When adding or changing a problem,
regenerate all three translated entries from the new English source, retain the
stable key and description, and update its source hash. When removing a problem,
remove its unused key from all four catalogs. The validator checks usage against
Rust call sites, `Response::problem` and `Response::problem_detail` alike, and
fails on any free-text `Response::error` in fabric-coordinator or resource-svc.
Every error those two services answer keeps its HTTP status and carries a
catalog `code`, with any former free text in `detail`: `upstream_unavailable`
when a dependency could not be reached, `upstream_failed` when it answered
unexpectedly, and one code per client error, such as `unknown_handle` or
`no_compliant_edge`. Consent and mandate refusals keep their `status` and
`reason`. Store failures in ledger-svc, seller-svc and resource-svc answer 503
`store_unavailable`. The coordinator's own stderr lines name the request ID.
ads-svc, audit-svc, connect-svc, identity-mock, insights-svc, ledger-svc,
platform-svc, seller-svc and slice-runtime still answer their other errors as
free text under `error` until they move to the catalog the same way.

See [test automation](../test.md#native-service-contract-checks) for verification.

## Deployment and client bounds

Ledger, seller and resource charts require exactly one replica and retain
`Recreate` rollout strategy because the three services cache database state.
Running additional replicas outside these charts is unsupported. Container builds
copy the committed Cargo lock and use `--locked`; dependency changes must update
that lock explicitly.

With `DATABASE_URL`, resource-svc writes each jurisdiction policy to
`resource.allocation_policies` before applying it and reloads the policies on
start, so a restart cannot let a restricted jurisdiction fall back to any
region; a refused write answers 503 `store_unavailable` and changes nothing.
Edge registrations stay in memory. A registration may carry `lease_secs`, an
integer from 1 to 3600 (anything else answers 400 `invalid_request`): the edge
lapses unless it registers again within that time, a lapsed edge gets no
placement, and `GET /v1/edges` reports `lease_remaining_secs`, 0 once lapsed. A
registration without a lease never lapses; the scenario scripts and demos
register that way. slice-runtime registers itself under a 30-second lease,
renewed every 10 seconds, only when started with `ADVERTISE_URL`, `REGION` and
`RESOURCE_URL`; no lab script sets `ADVERTISE_URL`.

The Flutter buyer imposes a 20-second total HTTP deadline including response body
reads. It closes the transport on timeout, ignores responses from earlier actions,
and disposes text controllers on screen removal. Starting a new match invalidates
an outstanding order refresh; the previous order cannot replace the new status.

The NATS installer compares the installed binary with its pinned version, replaces
older binaries, restarts on binary or unit changes, and verifies the live `/varz`
version before reporting success. Repeating an unchanged install does not restart
an active matching service. Demo firewall helpers check native exit codes and
elevation results; an existing Windows firewall rule does not skip the separate
HTTP URL reservation. A failed operation returns false and logs a warning.

## Lab deployment secrets

The amisad-core deploy step
(`test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`) makes two
secrets for each build and publishes each only as a Kubernetes Secret in the
`amisad` namespace.

`amisad_publish_database_password` gives the app role `amisad` a new password
and publishes it as Secret `amisad-database` (key `password`), which the ledger,
seller and resource charts read. 48 hex characters fit in `DATABASE_URL`
without escaping. It is the deploy step's first contact with the cluster and
the database, and kubectl does not retry a refused TCP dial, so it first waits,
up to its budget (300 seconds by default), for the apiserver's `/readyz` and
for `pg_isready`, and ensures the namespace, all before the ALTER: a cluster or
database that is still starting changes nothing. Only the Secret's delete and
create follow the ALTER. If either fails, the role is left on a password no
Secret carries and the step exits before helm; the next run sets a new password
and creates the Secret again unconditionally, so a re-run converges.

`amisad_publish_ledger_write_token` runs right after it and relies on its wait
for the apiserver and on the namespace. It makes a new token and publishes it
as Secret `amisad-ledger-write` (key `token`). The ledger-svc,
fabric-coordinator, seller-svc and platform-svc charts read it into
`LEDGER_WRITE_TOKEN`, and the scenario scripts read it from the Secret for the
edges' slice-runtime; ledger-svc refuses an append without it. A run that fails
exits before helm, and the next one makes a new token and creates the Secret
again.

Every run, a transport retry included, makes a new password and a new token.
Pods read both Secrets when they start, so a re-run leaves running pods on the
previous values until the readiness step restarts them before each scenario.

## Lab edge delivery

The helpers in `test/amisad-scenario.sh` deliver each build's slice-runtime to
the edge VMs.

- `amisad_edge_addr` prints an edge's address, or nothing, and returns 0
  either way: the caller decides what an unresolved edge means. `getent`
  answers first, because vm-core resolves the edge without the host when it
  can. Otherwise the address comes from the handoff file the host's status
  service serves. The host can take a new address while a scenario runs, when
  its DHCP lease expires and the server hands it another, and the coordinates
  in the environment are the ones the host had when the script started, so a
  fetch that fails is retried once after the guest's own locator has refreshed
  them.
- The edge VMs are never restored between scenarios, so the previous
  scenario's slice-runtime is still running when the next one delivers its
  binary. pkill returns as soon as SIGTERM is sent, not when the process is
  gone; until then, overwriting `/tmp/slice-runtime` fails with ETXTBSY (scp
  reports it as "dest open: Failure") and a fresh instance cannot bind the
  port. `amisad_stop_slice_runtime` therefore waits for the exit, and sends
  SIGKILL to an instance that outlives the SIGTERM allowance.
- `amisad_deliver_slice_runtime` copies the binary to an edge and starts it
  once the previous instance has exited. vm-core logs in as the edge admin with
  the demo keypair the users step generated in the admin home. Each step names
  the edge when it fails and returns that step's status, so the function
  behaves the same called plainly under errexit and inside `$( )`, where
  errexit does not reach. An empty region starts the runtime without a region
  identity, as an unset one does. Given an address variable, it also stores
  there the address the edge reports for itself, which can differ from the one
  it was reached at.
- The ledger write token reaches the edge on the start session's standard
  input, where the edge shell reads it into the runtime's environment.
  `amisad_ledger_write_token` writes it, then a newline, for that pipe;
  ledger-svc refuses appends without it. Without the Secret, as on a lab
  deployed by hand, the line is empty and a warning says so: the runtime then
  sends no token, which only a ledger started without one accepts.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
