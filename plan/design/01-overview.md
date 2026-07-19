# POC overview

> One sentence: the seven top-level blocks of the AmisAd POC and the four lab nodes they deploy to.

See [00-index.md](00-index.md) · [../design.md](../design.md).

## Level-1 components

```mermaid
flowchart TD
    buyer["Buyer mobile app<br/>Flutter · offline-first vault"]
    web["Web SPA shell<br/>7 role-scoped modules"]
    core["Application services<br/>seller · resource · ads · insights · platform · audit · connect"]
    found["Foundation services<br/>fabric-coordinator · identity-mock · ledger-svc"]
    edge["Slice runtime<br/>ephemeral match environments"]
    data["Data plane<br/>PostgreSQL · NATS JetStream"]
    yuruna["Yuruna harness<br/>provision · deploy · sequences"]

    buyer -->|"need envelopes · consent · order status"| found
    web -->|"REST /v1"| core
    core --> data
    found --> data
    found -->|"allocate · route envelope"| edge
    edge -->|"match records · attestation · aggregates"| found
    yuruna -.->|"provisions & verifies"| core
    yuruna -.-> edge
    yuruna -.-> buyer
```

| Block | Realization | Defined in |
|-------|-------------|-----------|
| Buyer mobile app | Flutter, side-loaded; the only holder of individual data | [02-buyer.md](02-buyer.md) |
| Web SPA shell | React + TS, one build, role-scoped modules, served from the cluster | docs 3–9 |
| Application services | Seven Rust services, one Cargo workspace | docs 3–9 |
| Foundation services | Fabric coordinator, OIDC-style mock issuer, three hash-chained ledgers | [../design.md](../design.md) §4 |
| Slice runtime | Stateless Rust binary on edge VMs; one process per match | [../design.md](../design.md) §2 |
| Data plane | One PostgreSQL (schema per service) + NATS JetStream, in-cluster | [../design.md](../design.md) §1 |
| Yuruna harness | VM provisioning, deployment, SCENARIO-001…010 as sequences | [../scenarios.md](../scenarios.md) |

## Deployment topology

```mermaid
flowchart LR
    subgraph host["Dev host"]
        runner["Yuruna runner + status"]
    end
    subgraph vmcore["vm-core · k3s"]
        apps["7 app services + SPA"]
        foundations["fabric-coordinator · identity-mock · ledger-svc"]
        pg[("PostgreSQL")]
        nats[["NATS JetStream"]]
    end
    subgraph vmedgea["vm-edge-a · region A"]
        rta["slice-runtime + attestation sim"]
    end
    subgraph vmedgeb["vm-edge-b · region B"]
        rtb["slice-runtime + attestation sim"]
    end
    subgraph device["Test mobile device"]
        flutter["Buyer app (side-loaded)"]
    end

    runner -.->|"provision · deploy · assert"| vmcore
    runner -.-> vmedgea
    runner -.-> vmedgeb
    flutter -->|"lab LAN"| foundations
    foundations -->|"allocations"| rta
    foundations --> rtb
    apps --> pg
    apps --> nats
    foundations --> pg
```

Two edge VMs are the minimum honest topology: SCENARIO-004 asserts a jurisdiction-restricted allocation choosing the compliant region, and SCENARIO-009 asserts one region above and one below the anonymity threshold. The slice VMs hold no state; a reboot must be indistinguishable from a fresh provision.
