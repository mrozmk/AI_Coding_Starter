import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-022 · source: code
test('CART-022 — See the cart total', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('status', { name: 'Total' })).toBeVisible();
});
