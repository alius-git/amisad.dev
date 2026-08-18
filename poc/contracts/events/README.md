# AmisAd event contracts (skeleton)

NATS JetStream subject families and their payload schemas. Empty by design:
each schema lands with the first scenario that publishes it.

Planned subject families (plan/design.md section 4): `orders.*`, `inventory.*`,
`campaigns.*`, `cases.*`. No subject may ever carry buyer identity or need
content - the privacy constraint is checked at this contract level.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
