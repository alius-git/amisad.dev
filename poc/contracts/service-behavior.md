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
  unbacked. An under-cap delegated commit keeps no hold: a retry after its
  failure is a new delegated need with a new match ID, and a settlement
  instruction the failed attempt wrote stays without its order.
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
  an identical replay answers 200 with the prior outcome. Neither that route nor
  `POST /v1/support/cases` takes a credential, so refunds stay reachable without
  one: anyone who reaches platform-svc can open a case for any match and refund
  it once. The token closes direct ledger appends, not this route.
- Audit certification requires a well-formed chain envelope, every row's payload
  and hashes, and a matching head. Explicit empty chains with the genesis head are
  accepted; missing evidence returns 502. Each environment must contain exactly
  `created`, `attested`, `executed` or `aborted`, then `destroyed`, in that order.
  Auditing compares settlement rows with the read-only instruction inventory:
  unique parties and exact amounts must match the confirmed instruction; a refund
  must negate every original party exactly once under one unique case. Orphan,
  duplicate, partial, excessive, or contradictory monetary evidence fails certification.
  Lifecycle rows are grouped in one pass.

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

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
