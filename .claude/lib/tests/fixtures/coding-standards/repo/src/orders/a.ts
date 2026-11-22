import { formatDate } from '../lib/dates';
import { toErrorBody } from '../lib/errors';

export interface Order {
  id: string;
  placedAt: Date;
}

export function describeOrder(order: Order): string {
  return `Order ${order.id} placed ${formatDate(order.placedAt)}`;
}

export function orderNotFound(id: string) {
  return toErrorBody('order_not_found', `No order ${id}`);
}
