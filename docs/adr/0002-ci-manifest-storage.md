# CI manifest storage: GitHub Actions artifact

The PR workflow (`ci.yml`) needs a prod `manifest.json` to run
`dbt build --select state:modified+ --defer --state <dir>` — without it, every
PR build rebuilds the whole warehouse instead of just the changed models and
their downstream. We produce that manifest with `dbt parse` in
`update-dbt-artifacts-and-docs.yml` on every push to `main`, upload it as a
GitHub Actions artifact named `dbt-manifest`, and fetch it in `ci.yml` via
`dawidd6/action-download-artifact`, filtered to the latest successful run of
that workflow on `main`. This is tracked under issue #20; this ADR records why
artifact storage won over the alternatives.

## Considered options

- **Committed `manifest.json` on `main`.** Rejected: `manifest.json` is a
  build output, not source — committing it means every merge to `main` needs a
  bot commit (or a pre-merge generation step) to keep it current, and it bloats
  git history with a large, frequently-changing generated file with no
  reviewable diff.
- **S3 bucket in `steam-infra`.** Rejected for now: would need new bucket
  provisioning, IAM/OIDC wiring between `steam-analytics`'s GitHub Actions and
  `steam-infra`'s AWS account, and lifecycle/cleanup policy — real
  infrastructure for a problem GitHub Actions artifacts already solve natively.
  Revisit if `steam-infra` ever needs the manifest for its own tooling.
- **GitHub Actions artifact, fetched with `gh run download -n dbt-manifest`
  (no run filter).** Rejected: per the `gh` CLI docs, omitting a run ID
  searches "across all runs in a repository" for a matching artifact name, with
  no built-in workflow/branch/conclusion filter. Fine today with one producing
  workflow, but silently ambiguous the moment a second workflow ever uploads an
  artifact under the same name.
- **Official `actions/download-artifact` with an explicit `run-id`.** Rejected:
  the action takes a `run-id` but has no lookup of its own — finding "latest
  successful run of workflow X on branch Y" means hand-rolling a
  `github-script` step against `listWorkflowRuns`, reinventing what
  `dawidd6/action-download-artifact` already does as a maintained input
  (`workflow`, `branch`, `workflow_conclusion`).

## Consequences

- **No extra infrastructure.** Manifest lifecycle rides GitHub's own artifact
  retention; nothing to provision or tear down alongside `steam-infra`.
- **Third-party action dependency.** `dawidd6/action-download-artifact` is not
  GitHub-maintained. `step-security/action-download-artifact` (a pinned/audited
  fork) is the drop-in replacement if supply-chain hardening becomes a
  requirement.
- **Manifest can be stale or missing.** If `update-dbt-artifacts-and-docs.yml`
  has never succeeded on `main` (first run, or a broken `main`), the PR
  workflow's artifact fetch fails closed rather than silently building
  everything — this is treated as acceptable since the failure is loud, not
  silent state drift.
- **Filtered by workflow file name, not by content.** The fetch step pins
  `workflow: update-dbt-artifacts-and-docs.yml`, `branch: main`,
  `workflow_conclusion: success` — renaming that workflow file requires
  updating this reference in `ci.yml` too.
