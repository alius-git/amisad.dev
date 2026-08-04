# AmisAd — the demos

Two ways to show the same live system, on the topology a green
[`test/amisad.end-to-end.yml`](../../test/amisad.end-to-end.yml) run leaves
behind. Both are half an hour, both drive the real NodePort APIs from a
browser, and both change nothing on the VMs beyond the calls the operator
clicks.

| | [`by-act/`](by-act/) | [`data-view/`](data-view/) |
|---|---|---|
| **Shape** | One scenario at a time: pick a persona, run its steps in order | Two windows at once: every persona's steps on one timeline, the machine's live state on the other |
| **Answers** | *What can the system do?* | *What does the system know about me?* |
| **Windows** | Console + deck | Actions + data view + deck |
| **Port** | 8091 | 8092 |
| **Start** | `pwsh poc/demo/by-act/serve-by-act.ps1` | `pwsh poc/demo/data-view/serve-data-view.ps1` |

Pick `by-act` to walk a first audience through the capabilities; pick
`data-view` when the room's real question is privacy, because it puts a
machine-checked answer on screen for the whole half hour.

Run them one at a time. They use different ports and different browser
storage so they *can* coexist, but two consoles writing to one lab during a
presentation muddies both stories.

## Both servers, same host behavior

`AmisAd.DemoHost.psm1` holds the parts that are about the host rather than
either demo, so the two behave identically:

- **They serve the network by default.** The banner leads with
  `http://<host-ip>:<port>/` — the address to type on a laptop, tablet or
  projector — and also lists any other interface plus the local `localhost`
  URL. `-BindAddress localhost` restricts a server to this machine;
  `-BindAddress 10.0.0.5` binds one NIC (localhost stays bound too).
- **They open the port.** On Ubuntu that is `ufw allow <port>/tcp` or
  `firewall-cmd --add-port`, prompting for `sudo`; on Windows an inbound rule
  plus the http.sys reservation a non-loopback listener needs, asking for
  administrator approval; on macOS, allowing this PowerShell through the
  application firewall (which filters by app, not port), prompting for `sudo`.
  Each is announced before it runs, is idempotent, and downgrades to a warning
  if declined. `-SkipFirewall` skips it entirely.
- **They stop from the keyboard.** Press **Ctrl+C**, **End** or **Q**. The
  request loop polls `GetContextAsync` instead of parking in the blocking
  `GetContext`, which would leave a server killable only by closing the
  terminal.
- **They gate the vault passwords per client, not per binding.** `/api/personas`
  serves real persona passwords to loopback requests — the host's own browser —
  and `<withheld: remote viewer>` to everyone else. `-SharePersonaPasswords`
  opts in for remote viewers, on a trusted network.

Shared parameters: `-Port`, `-YurunaRoot`, `-CoreIp`, `-EdgeAIp`, `-EdgeBIp`,
`-BindAddress`, `-SharePersonaPasswords`, `-SkipFirewall`.

## Prerequisites

- The end-to-end run finished green and the machines are still up:
  `amisad-core` (services on NodePorts 30080–30089) and both edges running
  `slice-runtime`. If a VM rebooted since, re-arm per
  [demo.md](../demo.md#driving-the-demo) first.
- A Yuruna checkout, discovered automatically — it supplies the persona vault
  passwords and the VM power states. Everything else works without it.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
