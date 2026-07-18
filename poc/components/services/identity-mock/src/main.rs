// AmisAd POC skeleton: OIDC-style token issuer standing in for Identity and Verification.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "identity-mock",
        version: env!("CARGO_PKG_VERSION"),
    })
}