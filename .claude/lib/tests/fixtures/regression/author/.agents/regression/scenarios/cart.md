# Cart

### CART-004 — See the cart heading
- **Priority:** P1 · **Viewport:** both · **Status:** READY · **Effect:** read
- **Goal:** Open the cart and see it.
- **Steps:**
  1. Open the cart.
- **Expected:** The cart heading is visible.
- **Source:** E2-3.AC2 [a1b2c3] · **Spec:** —

### CART-005 — Clear the cart
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** write
- **Goal:** Remove every cart line.
- **Steps:**
  1. Clear the cart.
- **Expected:** The cart is empty.
- **Source:** live · **Spec:** —

### CART-006 — Apply a voucher
- **Priority:** P1 · **Viewport:** desktop · **Status:** BLOCKED (#12) · **Effect:** read
- **Goal:** Apply a voucher.
- **Steps:** —
- **Expected:** —
- **Source:** live · **Spec:** —

### CART-007 — Cart totals
- **Priority:** P0 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Goal:** See the totals.
- **Steps:**
  1. Open the cart.
- **Expected:** Totals are shown.
- **Source:** live · **Spec:** e2e/regression/cart/cart-007.spec.ts › CART-007 — Cart totals

### CART-008 — The total follows a quantity change
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Goal:** See the total follow the quantity.
- **Steps:**
  1. Change a quantity.
- **Expected:** The total follows.
- **Source:** E2-3.AC3 [d4e5f6] · **Spec:** —

### CART-009 — The cart badge
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Goal:** See the cart badge.
- **Steps:**
  1. Open any page.
- **Expected:** The badge shows the line count.
- **Source:** E2-3.AC4 [0a0b0c] · **Spec:** —

### CART-010 — The cart looks right
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Goal:** See the cart layout.
- **Steps:**
  1. Open the cart.
- **Expected:** The lines are listed.
- **Source:** E2-3.AC5 [111111] · **Spec:** —
