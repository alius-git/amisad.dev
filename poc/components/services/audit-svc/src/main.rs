// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 alius-git
// AmisAd POC skeleton: Independent verification of ledgers, attestation chains, residency, and consent.
// Serves GET /health and GET /version; real routes arrive with the scenarios.

fn main() -> std::io::Result<()> {
    amisad_common::serve(amisad_common::ServiceInfo {
        name: "audit-svc",
        version: env!("CARGO_PKG_VERSION"),
    })
}