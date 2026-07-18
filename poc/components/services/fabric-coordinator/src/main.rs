// AmisAd POC skeleton: Routes encrypted need envelopes to sealed slice environments per jurisdiction policy.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "fabric-coordinator",
        version: env!("CARGO_PKG_VERSION"),
    })
}