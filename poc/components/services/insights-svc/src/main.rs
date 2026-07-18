// AmisAd POC skeleton: Threshold-protected aggregate demand insights and outlooks.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "insights-svc",
        version: env!("CARGO_PKG_VERSION"),
    })
}