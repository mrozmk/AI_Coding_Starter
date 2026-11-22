import { formatDate } from '../lib/dates';
import { toErrorBody } from '../lib/errors';

export interface Invoice {
  id: string;
  issuedAt: Date;
  total: number;
}

export function invoiceLabel(invoice: Invoice): string {
  return `Invoice ${invoice.id} issued ${formatDate(invoice.issuedAt)}`;
}

export function invoiceNotFound(id: string) {
  return toErrorBody('invoice_not_found', `No invoice ${id}`);
}
