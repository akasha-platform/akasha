---
status: accepted
date: 2026-11-11
decision-makers: dhuy21
---

# Dependency updates with Renovate and an allow-list of GitHub Actions

## Context and Problem Statement

Every tool and action is pinned (ADR-0022, ADR-0023). Pins go stale and miss security fixes
unless something proposes updates. The update mechanism must respect the 6-day release
cooldown, cover every pinned file (`mise.toml` + `mise.lock`, `pyproject.toml` + `uv.lock`,
`.python-version`, SHA-pinned actions, the CI mise version), and must not weaken the
read-only CI model (ADR-0013). Separately, the organisation still allows any action to run.

## Considered Options

* **Renovate, Mend-hosted GitHub App** (Community Cloud, free)
* Dependabot version updates (first party, but no `mise` or `aqua` ecosystem: the eight mise
  tools would need manual updates)
* Renovate self-hosted in GitHub Actions (needs a GitHub App or PAT secret with write access in
  a public repository)
* No bot (manual updates only)

## Decision Outcome

Chosen option: "Renovate, Mend-hosted GitHub App", installed on the `akasha` repository only.

* Mend Developer Portal settings (outside the repository): organisation default **Silent mode
  on** (a newly added repository stays silent until enabled on purpose); for `akasha`: Silent
  mode off, **Automated PRs on**, **Require config file on** (no pull requests without
  `.github/renovate.json5`), Create onboarding PRs off.

* Configuration in `.github/renovate.json5`:
  * `config:best-practices` (SHA-pinned action digests, dependency dashboard), Conventional
    Commits, schedule `before 6am on monday` (Europe/Paris), **no automerge**;
  * `minimumReleaseAge: "6 days"` with `internalChecksFilter: strict`; security fixes are exempt;
  * `constraints.mise = 2026.11.1`: the mise that Renovate runs for `mise lock` (≥ 2026.7.12
    runs in safe mode, so no `allowedUnsafeExecutions` is needed); kept equal to `min_version`
    in `mise.toml` by hand, changed only when the lockfile format changes. The CI mise
    (`version:` of `jdx/mise-action`) is extracted and updated by Renovate;
  * lock file maintenance (`mise.lock`, `uv.lock`) on the first day of the month;
  * `pep621`: `rangeStrategy: update-lockfile` (ranges stay as written); `ansible-core` held
    below 2.21 for kolla-ansible 2026.1; `.python-version` bumps need dashboard approval
    (a CPython release can precede its uv-managed build); the Python minor version (3.15+,
    `.python-version` and `requires-python` together) and `constraints.mise` move by hand;
    a new runner image (`runs-on`, e.g. ubuntu-26.04) and a new uv 0.x series (raise
    `required-version` in the same pull request) need dashboard approval.
* **uv cooldown**: `exclude-newer = "6 days"` instead of a fixed timestamp. `uv.lock` records
  the span (`exclude-newer-span = "P6D"`); the cutoff is recomputed only when the lock is
  re-resolved, so `uv sync --locked` stays reproducible. Renovate passes no cooldown to uv, so
  this setting is what enforces the cooldown for Python packages, including lock file
  maintenance.
* **Dependabot**: alerts stay on (Renovate reads them through `vulnerabilityAlerts`);
  Dependabot security updates are switched off so only one bot opens fix pull requests.
* **Allowed actions** (organisation level, both repositories): `allowed_actions: selected`,
  GitHub-owned and verified-creator actions **not** allowed wholesale, explicit patterns only:
  `actions/checkout@*`, `jdx/mise-action@*`. `sha_pinning_required` stays on. Each later étape
  adds the actions it needs.

### Consequences

* Good, because every pinned file is covered by one bot with one cooldown, and the repository
  holds no write-capable secret.
* Good, because a workflow can no longer run an action that was not reviewed and listed.
* Bad, because the Mend app has write access to code (contents), pull requests, issues, checks,
  commit statuses and workflows, and read access to administration, members, packages and
  Dependabot alerts (verified on the installation, 2026-11-11); mitigated by owner review of
  every pull request (and, in Étape 7, rulesets on `main`).
* Bad, because a Renovate-run `mise lock` ignores the project `[settings]` (safe mode); whether
  its output (checksums, provenance lines) matches a local `mise lock` must be checked on the
  first `mise.lock` pull request. Fallback: manual re-lock.
* `min_version` (`mise.toml`), `constraints.mise` and `required-version` (`pyproject.toml`,
  bounds the uv version) are updated by hand.
* Not adopted yet: GitHub workflow lockfiles (`actions.lock`, GA 2026-10-28); to be decided
  separately.

### Confirmation

* `renovate-config-validator --strict` (Renovate 44.216.2) accepted `.github/renovate.json5`
  as repository configuration on 2026-11-11.
* `uv lock` with the relative cutoff resolved the same 38 packages; only the `[options]` block
  of `uv.lock` changed.
* Allow-list (2026-11-11): on a temporary branch, a workflow using `actions/setup-python`
  (full commit SHA) ended in `startup_failure`; the same workflow using `actions/checkout`
  succeeded; `lint` on `main` stayed green.
* Dependency dashboard (issue #12): all eight mise tools, both actions, the CI mise version,
  `.python-version` and the uv dependencies detected; updates under 6 days old wait in
  "Pending Status Checks", older ones in "Awaiting Schedule"; only the runner image needs
  approval. The first run proposed Python 3.15, `constraints.mise` and ubuntu-26.04: fixed by
  rules in #11.
* First `mise.lock` update (#13, uv 0.13.6 → 0.13.7): Renovate's `mise.toml` and `mise.lock`
  were byte-identical to a local `mise lock`; the checksum matched uv's official `.sha256`;
  `provenance = "github-attestations"` kept; commit signed; `lint` and
  `renovate/stability-days` passed.
* Dependabot: security updates disabled and alerts enabled on both repositories (API).

## More Information

Research: [research/06](../research/06-cicd-supply-chain.md). Renovate mise manager:
https://docs.renovatebot.com/modules/manager/mise/ (safe mode in
`lib/modules/manager/mise/artifacts.ts`); minimum release age:
https://docs.renovatebot.com/key-concepts/minimum-release-age/; uv `exclude-newer`:
https://docs.astral.sh/uv/reference/settings/#exclude-newer; allowed actions API:
https://docs.github.com/en/rest/actions/permissions.
