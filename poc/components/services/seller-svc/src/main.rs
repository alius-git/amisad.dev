// AmisAd POC skeleton: Seller catalog, inventory, order lifecycle, and settlement views.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "seller-svc",
        version: env!("CARGO_PKG_VERSION"),
    })
}