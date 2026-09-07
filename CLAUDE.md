## Running commands

Run every Python tool in this repo — `dbt`, `sqlfluff` — through `uv run`, which
resolves them against the project's `.venv` and `requirements.txt`:

```
uv run dbt parse
uv run sqlfluff lint .
```

Ask the user first before installing anything globally.

## Agent skills

### Issue tracker

Issues tracked in GitHub Issues (Dulain-Willis/steam-analytics), via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout: `CONTEXT.md` + `docs/adr/` at repo root (created lazily). See `docs/agents/domain.md`.
