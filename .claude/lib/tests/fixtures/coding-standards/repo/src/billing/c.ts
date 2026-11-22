import { Invoice } from './b';

// Reminder text uses the locale date, unlike the rest of billing.
export function reminderText(invoice: Invoice): string {
  const due = invoice.issuedAt.toLocaleDateString('en-GB');
  return `Invoice ${invoice.id} is due since ${due}`;
}

export function reminderSubject(invoice: Invoice): string {
  return `Reminder: invoice ${invoice.id}`;
}

export const REMINDER_DAYS = 14;
