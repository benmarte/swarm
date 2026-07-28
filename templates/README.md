# templates/

Comment body templates rendered by `scripts/render-comment.sh`.

## templates/comments/

Per-stage findings comment templates. Each is a Python `string.Template` — variables use `${NAME}` syntax, rendered injection-safe via `safe_substitute`.

| Template | Stage | Posted on |
|----------|-------|-----------|
| `validator-verdict.md` | intake (validator) | issue — every verdict |
| `pr-opened.md` | develop | issue — after PR created |
| `review-signoff.md` | pr-gates (reviewer) | PR |
| `security-signoff.md` | pr-gates (security) | PR |
| `blocked.md` | pr-gates (security fail) | issue |
| `docs-posted.md` | docs | issue |
| `issue-closed.md` | docs (close) | issue |

Common variables: `${HEADER}`, `${VERDICT}`, `${SUMMARY}`, `${DETAILS}`.
Stage-specific variables: `${PR}` (pr-opened, issue-closed).

Set `comments.enabled: false` in `swarm.config.yml` to suppress all comment posting.
