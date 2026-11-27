# Product page

### PDP-001 — See the price
- **Priority:** P0 · **Viewport:** both · **Status:** READY · **Effect:** read
- **Needs:** price-call
- **Goal:** The product page shows a price.
- **Steps:**
  1. Open a product page.
- **Expected:** A price is shown.
- **Source:** live · **Spec:** e2e/regression/pdp.spec.ts › PDP-001 — See the price

### PDP-002 — See the stock
- **Priority:** P1 · **Viewport:** desktop · **Status:** READY · **Effect:** read
- **Needs:** price-unbounded
- **Goal:** The product page shows the stock.
- **Steps:**
  1. Open a product page.
- **Expected:** The stock is shown.
- **Source:** live · **Spec:** e2e/regression/pdp.spec.ts › PDP-002 — See the stock

### PDP-003 — Open the gallery
- **Priority:** P0 · **Viewport:** mobile · **Status:** READY · **Effect:** read
- **Goal:** Open the product gallery.
- **Steps:**
  1. Open a product page.
  2. Tap the image.
- **Expected:** The gallery opens.
- **Source:** live · **Spec:** e2e/regression/pdp.spec.ts › PDP-003 — Open the gallery
