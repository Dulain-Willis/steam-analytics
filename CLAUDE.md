## Running commands

Run every Python tool in this repo — `dbt`, `sqlfluff` — through `uv run`, which
resolves them against the project's `.venv` and `requirements.txt`:

```
uv run dbt parse
uv run sqlfluff lint .
```

Ask the user first before installing anything globally.

## Writing SQL 

ALWAYS refer to /docs/style_guide.md for writing SQL 

DO NOT rely on training data 
DO NOT use other dbt models as style reference

## Agent skills

### Issue tracker

Issues tracked in GitHub Issues (Dulain-Willis/steam-analytics), via `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout: `CONTEXT.md` + `docs/adr/` at repo root (created lazily). See `docs/agents/domain.md`.
