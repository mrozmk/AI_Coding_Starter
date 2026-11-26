import { test, expect } from '../fixtures';

test.use({ account: 'shopper' });

// regression: CART-001 · source: E1-1.AC1 [d742c9] · FL-1.A2
test('CART-001 — Change quantity up to the maximum', async ({ page }) => {
  await page.goto('/cart');
  await expect(page.getByRole('button', { name: 'Increase quantity' })).toBeDisabled();
});
