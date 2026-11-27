import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-004 · source: E2-3.AC2 [a1b2c3]
test('CART-004 — See the cart heading', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await page.waitForTimeout(1000);
  await expect(page.locator('.cart h1')).toBeVisible();
});
