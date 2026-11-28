import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-008 · source: live
test('CART-008 — See the cart summary', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('heading', { name: 'Summary' })).toBeVisible();
});
