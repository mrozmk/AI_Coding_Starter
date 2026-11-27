# Cart

### CART-001 — Open the cart
- **Priority:** P0 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Goal:** Open the cart page and see it.
- **Steps:**
  1. Open the cart.
- **Expected:** The cart heading is visible.
- **Source:** live · **Spec:** e2e/regression/cart.spec.ts › CART-001 — Open the cart

### CART-002 — Add to cart as a shopper
- **Priority:** P0 · **Viewport:** both · **Status:** READY · **Effect:** write
- **Needs:** account:shopper
- **Goal:** A signed-in shopper adds a product to the cart.
- **Steps:**
  1. Sign in as the shopper.
  2. Add a product.
- **Expected:** The cart shows one item.
- **Source:** live · **Spec:** e2e/regression/cart.spec.ts › CART-002 — Add to cart as a shopper

### CART-003 — Empty the cart
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** write
- **Goal:** Remove every item from the cart.
- **Steps:**
  1. Remove the items.
- **Expected:** The cart is empty.
- **Source:** live · **Spec:** e2e/regression/cart.spec.ts › CART-003 — Empty the cart

### CART-004 — Pay with the sandbox
- **Priority:** P1 · **Viewport:** mobile · **Status:** READY · **Effect:** write
- **Needs:** payment:sandbox
- **Goal:** Pay for the cart with the sandbox payment means.
- **Steps:**
  1. Check out.
- **Expected:** The order confirmation shows.
- **Source:** live · **Spec:** e2e/regression/cart.spec.ts › CART-004 — Pay with the sandbox

### CART-005 — Apply a voucher
- **Priority:** P1 · **Viewport:** desktop · **Status:** BLOCKED (#12) · **Effect:** read
- **Goal:** Apply a voucher to the cart.
- **Steps:** —
- **Expected:** —
- **Source:** live · **Spec:** —

### CART-006 — Old cart badge
- **Priority:** P1 · **Viewport:** desktop · **Status:** DROPPED (badge removed) · **Effect:** read
- **Goal:** See the old cart badge.
- **Steps:** —
- **Expected:** —
- **Source:** live · **Spec:** —

### CART-007 — Cart totals
- **Priority:** P0 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Goal:** See the cart totals.
- **Steps:**
  1. Open the cart.
- **Expected:** Totals are shown.
- **Source:** live · **Spec:** —
