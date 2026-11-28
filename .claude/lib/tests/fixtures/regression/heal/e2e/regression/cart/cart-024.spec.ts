import { test, expect } from '../../fixtures';

test.use({ account: null });

// regression: CART-024 · source: live
test('CART-024 — Remove a line', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await page.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByRole('listitem')).toHaveCount(0);
});

// regression: CART-025 · source: live
test('CART-025 — Restore a line', { tag: ['@regression'] }, async ({ page }) => {
  await page.goto('/cart');
  await page.getByRole('button', { name: 'Restore' }).click();
  await expect(page.getByRole('listitem')).toHaveCount(1);
});
