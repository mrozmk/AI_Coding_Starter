import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-010 · source: live
test('CART-010 — Clear the cart', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('heading', { name: 'Empty' })).toBeVisible();
});
