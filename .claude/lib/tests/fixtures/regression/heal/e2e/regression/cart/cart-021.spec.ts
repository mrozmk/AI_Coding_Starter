import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-021 · source: live
test('CART-021 — See the cart heading', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('heading', { name: 'Cart' })).toBeVisible();
});
