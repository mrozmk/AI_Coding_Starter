# E1 — Cart

## E1-1 — Change quantity
**Summary:** Change quantity for the shop.
**Goal:** deliver change quantity.
**In scope:** the happy path and its errors.
**Out of scope:** admin tooling.
### Acceptance criteria
- **E1-1.AC1** — [reg P0] Given one line in the cart, when the quantity is raised to the maximum, then the line total follows.
- **E1-1.AC2** — Given an empty cart, when the cart opens, then the empty state shows.

## E1-2 — Vouchers
**Summary:** Vouchers for the shop.
**Goal:** deliver vouchers.
**In scope:** the happy path and its errors.
**Out of scope:** admin tooling.
### Acceptance criteria
- **E1-2.AC1** — [reg P1] Given a valid voucher, when it is applied, then the discount shows.
