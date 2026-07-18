// AmisAd POC skeleton: Append-only hash-chained consent, settlement, and attestation ledgers.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "ledger-svc",
        version: env!("CARGO_PKG_VERSION"),
    })
}