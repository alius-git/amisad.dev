// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC skeleton: Campaign administration and creative studio marketplace.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "ads-svc",
        version: env!("CARGO_PKG_VERSION"),
    })
}