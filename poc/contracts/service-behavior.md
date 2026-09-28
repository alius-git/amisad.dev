# Service behavior and recovery

The POC services share a small HTTP server. Aggregate request lines and headers
are limited to 32 KiB, bodies to 1 MiB, and the whole request read to 20 seconds.
Oversized requests return 413, malformed framing returns 400, and an expired read
returns 408. Duplicate Content-Length and Transfer-Encoding are rejected. Bodies
must be UTF-8. Responses have a five-second write timeout.

## Ownership and retries

- Connector catalog and inventory calls use the tenant attached to the authorized
  credential. Catalog batches with a different tenant are rejected before forwarding.
  Seller offer ownership cannot be changed by an upsert, including at the SQL boundary.
  Seller inventory updates require `tenant` as well as `offer_id` and `stock`.
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
- Fulfillment advances an order to `settled` only after ledger confirmation.
  Confirmation failure returns 503 without advancing the order. Repeating the
  confirmation is safe, including after service restart or an ambiguous response.
  Previously stranded `fulfilled` rows can be retried through the same endpoint.
- A full refund is identified by match and case. The adjustment entries themselves
  are its durable replay record, committed together. An identical replay returns
  200 with the previous outcome and appends nothing. A different case, case reuse
  for another match, or inconsistent prior compensation returns 409. Historical
  duplicate refunds are never silently deleted or repaired.
- Audit certification requires a well-formed chain envelope, every row's payload
  and hashes, and a matching head. Explicit empty chains with the genesis head are
  accepted; missing evidence returns 502. Monetary conservation and strict lifecycle
  ordering are separate pending validations, so a successful certificate does not
  yet prove those properties.

## Localized problem messages

New problem responses carry a stable `code` and localized `error`. Clients branch
on HTTP status and `code`, never on translated text. `Accept-Language` selects
`en-US`, `pt-BR`, `zh-CN`, or `he-IL`, honoring positive quality weights and language
fallbacks. Unsupported languages fall back to English. `AMISAD_LOCALE` selects the
process default when no request language is supplied. Protocol keys, IDs, route
names, and order states remain unchanged. JSON is UTF-8, including Hebrew text;
consuming UIs are responsible for text direction and bidi isolation around IDs.

Catalogs live in `components/lib/amisad-common/locales/` and are embedded by Cargo
and Bazel. Non-English entries are machine-generated drafts with English source
hashes and provenance; they await linguistic review. `test/check_messages.py`
rejects missing, unused, empty, or stale entries. When adding or changing a problem,
regenerate all three translated entries from the new English source, retain the
stable key and description, and update its source hash. When removing a problem,
remove its unused key from all four catalogs. The validator checks usage against
Rust call sites. Developer diagnostics and existing legacy API errors have not
been migrated into this new catalog.

See [test automation](../test.md#native-service-contract-checks) for verification.
