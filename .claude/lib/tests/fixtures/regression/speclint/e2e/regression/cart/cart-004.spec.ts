import { test, expect } from '../../fixtures';
import { openCart } from './helpers/cart';

test.use({ account: null });

// regression: CART-004 · source: live
test('CART-004 — Open the cart', { tag: ['@regression', '@smoke'] }, async ({ page }) => {
  await openCart(page);
  await expect(page.getByRole('heading', { name: 'Cart' })).toBeVisible();
});
