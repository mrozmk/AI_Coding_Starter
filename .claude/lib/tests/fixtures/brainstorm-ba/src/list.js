// Reading list — the fixture's whole product code.

export function addBook(list, title, author) {
  list.books.push({ title, author, read: false, readAt: null });
  return list;
}

export function markRead(list, title, now = new Date()) {
  const book = list.books.find((b) => b.title === title);
  if (!book) throw new Error(`no book ${title}`);
  book.read = true;
  book.readAt = now.toISOString();
  return book;
}

export function exportCsv(list) {
  const rows = list.books.map((b) => [b.title, b.author, b.read ? 'read' : 'unread'].join(','));
  return ['title,author,state', ...rows].join('\n');
}

export function isVisibleTo(list, user) {
  return list.owner === user;
}
