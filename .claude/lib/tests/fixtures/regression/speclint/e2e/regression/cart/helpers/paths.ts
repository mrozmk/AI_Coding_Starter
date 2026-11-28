// A second-level helper: imports the first one back (a cycle the scan must survive).
import { openCart } from './cart';

export const CART_PATH = '/cart';
export const again = openCart;
