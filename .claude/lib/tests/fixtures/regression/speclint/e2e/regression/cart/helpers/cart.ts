// A relative helper the conforming spec imports: scanned with the network, process, import and route rules.
import { CART_PATH } from './paths';

export async function openCart(page) {
  await page.goto(CART_PATH);
}
