// AmisAd POC skeleton: Carrier control plane: allocation policy, slice controller, telemetry, incidents.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "resource-svc",
        version: env!("CARGO_PKG_VERSION"),
    })
}