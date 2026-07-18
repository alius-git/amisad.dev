// AmisAd POC skeleton: Stateless edge match runtime with simulated attestation.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "slice-runtime",
        version: env!("CARGO_PKG_VERSION"),
    })
}