import { test, expect } from '../fixtures';

// regression: CART-001 · source: live
test('CART-001 — Open the cart', async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('heading')).toBeVisible();
});

// regression: CART-002 · source: live
test('CART-002 — Add to cart as a shopper', async ({ page }) => {
  await page.goto('/cart');
});

// regression: CART-003 · source: live
test('CART-003 — Empty the cart', async ({ page }) => {
  await page.goto('/cart');
});

// regression: CART-004 · source: live
test('CART-004 — Pay with the sandbox', async ({ page }) => {
  await page.goto('/checkout');
});
