// Date formatting shared by every module.
export function formatDate(value: Date): string {
  const year = value.getUTCFullYear();
  const month = String(value.getUTCMonth() + 1).padStart(2, '0');
  const day = String(value.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function parseIsoDate(text: string): Date {
  const parsed = new Date(text);
  if (Number.isNaN(parsed.getTime())) {
    throw new Error(`invalid date: ${text}`);
  }
  return parsed;
}
