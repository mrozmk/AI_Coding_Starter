# E1 — Reading list

## E1-1 — Add a book
**Summary:** A reader adds a book to their list.
**Goal:** readers can collect the books they want to read.
**In scope:** adding a book by title and author.
**Out of scope:** importing lists from other services.
### Acceptance criteria
- **E1-1.AC1** — Given a signed-in reader, when they add a book by title and author, then the book shows on their list.

## E1-2 — Mark a book as read
**Summary:** A reader marks a book on their list as read.
**Goal:** readers see which books they have finished.
**In scope:** marking a book as read and showing that state.
**Out of scope:** reading statistics.
### Acceptance criteria
- **E1-2.AC1** — Given a book on the list, when the reader marks it as read, then the book shows a read badge.
- **E1-2.AC2** — Given a book marked as read, when the list is saved, then the read date is stored.

## E1-3 — Private lists
**Summary:** A reading list is visible only to its owner.
**Goal:** no reader sees another reader's list.
**In scope:** the visibility check on every list view.
**Out of scope:** sharing of any kind.
### Acceptance criteria
- **E1-3.AC1** — Given a list owned by one reader, when another reader opens it, then access is refused.
