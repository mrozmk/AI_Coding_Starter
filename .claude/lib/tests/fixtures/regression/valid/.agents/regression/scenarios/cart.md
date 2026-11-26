# Cart — regression scenarios

### CART-001 — Change quantity up to the maximum
- **Priority:** P0 · **Viewport:** both · **Status:** READY · **Effect:** write
- **Data:** signed-in test account with one in-stock line in the cart
- **Goal:** Raise one cart line to the maximum quantity and confirm the totals follow.
- **Steps:**
  1. Open the cart with one line in it.
  2. Increase the quantity with the stepper until it stops.
- **Expected:** The stepper stops at the maximum, the increase control is disabled, and the line
  total equals unit price × quantity.
- **Source:** E1-1.AC1 [d742c9] · FL-1.A2 · **Spec:** e2e/regression/cart.spec.ts › CART-001 — Change quantity up to the maximum

### CART-002 — Remove the last line
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** write
- **Goal:** Remove the only cart line and see the empty state.
- **Steps:**
  1. Open the cart with one line in it.
  2. Remove the line.
- **Expected:** The empty-cart message shows and the total is zero.
- **Source:** live · **Spec:** —

### CART-003 — Apply a voucher
- **Priority:** P1 · **Viewport:** both · **Status:** BLOCKED (E1-2) · **Effect:** write
- **Goal:** Apply a valid voucher and see the discount.
- **Steps:** —
- **Expected:** —
- **Source:** code · **Spec:** —
