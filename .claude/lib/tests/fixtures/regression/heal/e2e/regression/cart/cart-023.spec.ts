import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-023 · source: E1-1.AC1 [aaaaaa]
test('CART-023 — See the cart lines', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('list', { name: 'Lines' })).toBeVisible();
});
