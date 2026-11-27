import { test, expect } from '../../fixtures';

test.use({ account: 'shopper' });

// regression: CART-009 · source: live
test('CART-009 — Cart as a shopper', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('heading', { name: 'Your cart' })).toBeVisible();
});
