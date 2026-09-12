# Attachments: uploading files to a Jira issue

Load this file when a create (or update) carries files to attach — typically screenshots
proving a Bug. Contract: **stage → attach → verify → clean up.**

---

## 1. Stage

The MCP server sandboxes attachment paths to the **project root**. A path that resolves
outside it is rejected with:

```
Path traversal detected: <path> resolves outside /path/to/project
```

This hits the normal cases, not the exotic ones — a screenshot on the Desktop, in `/tmp`, or
in the session scratchpad is rejected even when the harness can read it. So:

- Path already inside the project root → use as-is. Relative paths resolve against the
  project root and are the cleanest form.
- Any other path → copy it to `.jira-attachments/` at the repo root first (gitignored), then
  attach from there. **This is the normal path, not an exception.**

## 2. Attach

Only after the issue exists — the key is required.

```
jira_update_issue(
    issue_key="<KEY>",
    fields="{}",
    attachments="<path1>,<path2>",
    return_fields="key"
)
```

- `fields="{}"` is a valid no-op — attaching does not require changing a field.
- `attachments` takes a comma-separated list or a JSON array of paths.
- `return_fields="key"` keeps the response small; the attachment result is returned regardless.

## 3. Verify — read `uploaded[]` and `failed[]`, never `success`

**The top-level `success` flag lies.** A totally failed upload still returns:

```json
{ "success": true, "total": 1, "uploaded": [], "failed": [{ "filename": "…", "error": "…" }] }
```

A file counts as attached **only** when it appears in `uploaded[]`. Report every entry in
`failed[]` by filename with its error. Never claim an attachment that is not in `uploaded[]`.

Uploaded entries carry `"id": null`. To obtain a real attachment id — to link it or delete it
— follow up with `jira_get_issue(issue_key="<KEY>", fields="attachment")`.

## 4. Clean up

Delete the staged copies from `.jira-attachments/` once the upload is verified. Leave files
that failed to upload in place and say where they are, so the user can retry.

## 5. REST fallback

Needed when the sandbox blocks a path that cannot be copied, and **mandatory for deletion** —
`mcp-atlassian` has no delete-attachment tool.

```bash
# attach
curl -s -u "$JIRA_USERNAME:$JIRA_API_TOKEN" -H "X-Atlassian-Token: no-check" \
  -F "file=@<path>" "$JIRA_URL/rest/api/3/issue/<KEY>/attachments"

# delete — id comes from jira_get_issue(fields="attachment"); the upload response returns null
curl -s -X DELETE -u "$JIRA_USERNAME:$JIRA_API_TOKEN" \
  "$JIRA_URL/rest/api/3/attachment/<id>"
```

`X-Atlassian-Token: no-check` is mandatory — a `403` usually means it is missing. Credentials
come from the repo-root `.env`; never echo their values into the transcript or a Jira field.

**The skill must not run these itself.** `curl -F` / `curl -X` are denied by the egress policy in
`.claude/settings.json` (see CLAUDE.md → Security), and sourcing `.env` into a shell is denied too. Print the ready-to-run command and ask the user to
execute it with a leading `!`, then report the result they get. Never report a deletion or a
fallback upload that was never executed.

---

## Failure modes

| Symptom                                     | Cause                              | What to report                                                     |
| ------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------ |
| `Path traversal detected: …`                | Path outside the project root      | Stage into `.jira-attachments/` and retry — do not surface as fatal |
| File missing / unreadable                    | Bad path from the user             | Name the path, create the issue anyway, list it as un-attached     |
| `success: true` but `failed[]` is non-empty | The flag is unreliable             | Treat as failure; report the `failed[]` filenames                  |
| Some uploaded, some failed                  | Partial upload                     | Issue key + attached filenames + failed filenames, all three       |
| `403`                                        | Missing `X-Atlassian-Token` header | Retry once with the header; then report                            |
| `413`                                        | Over the instance attachment limit | Name the file and its size; suggest compressing                    |

A failed upload **never** invalidates the created issue. Always report the issue key first,
then the attachment outcome.
