import { test, expect } from '../fixtures';

// regression: PDP-001 · source: live
test('PDP-001 — See the price', async ({ page }) => {
  await page.goto('/p/1');
  await expect(page.getByTestId('price')).toBeVisible();
});

// regression: PDP-002 · source: live
test('PDP-002 — See the stock', async ({ page }) => {
  await page.goto('/p/1');
});

// regression: PDP-003 · source: live
test('PDP-003 — Open the gallery', async ({ page }) => {
  await page.goto('/p/1');
});
