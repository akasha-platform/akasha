---
status: accepted
date: 2026-11-10
decision-makers: dhuy21
---

# Local git hooks and lint CI share one check list

## Context and Problem Statement

Mistakes (secrets, unformatted IaC, insecure workflows, broken YAML) must be caught before
they reach `main`, on the laptop and again on GitHub, with exactly the same tool versions
(ADR-0022) and without weakening the CI security model of a public repository (ADR-0013).

## Decision Outcome

* **One list of checks** in `.pre-commit-config.yaml`, run by pre-commit 4.7:
  * generic hygiene from `pre-commit/pre-commit-hooks` pinned by SHA (frozen v6.0.0): whitespace,
    end of file, LF line endings, YAML/TOML/JSON syntax, merge markers, case conflicts, large
    files, shebangs, **private keys**, **no commit to `main`**;
  * `repo: local` hooks that call the pinned tools through `mise exec --` / `uv run --locked`
    (no third version-pinning layer): gitleaks, tofu fmt, tflint, trivy config, actionlint,
    zizmor (offline), shellcheck, yamllint, ansible-lint.
* **Local git hook**: `pre-commit install` (per clone). The `no-commit-to-branch` hook makes
  every change go through a branch and a pull request.
* **CI** (`.github/workflows/lint.yml`) on GitHub-hosted `ubuntu-24.04`, on pull requests,
  pushes to `main` and manual runs:
  * `permissions: {}` at workflow level, `contents: read` for the job; no secrets;
    `actions/checkout` v7.0.1 and `jdx/mise-action` v5.2.6 pinned by full SHA;
    `persist-credentials: false`; `MISE_SAFE=1`; no cache (cache poisoning avoided; revisit if slow);
  * mise `2026.11.1` (oldest release able to read lockfile format v4) — the pull request that
    introduces CI is opened only once that release is 7 days old (2026-11-11);
  * steps: `mise install --locked` (by the action), `uv sync --locked`, pre-commit on all files
    (`SKIP=no-commit-to-branch`), gitleaks on the **full history**, zizmor with **online**
    audits using the read-only token.

### Consequences

* Good, because the same checks and versions run locally and in CI, and the workflow itself is
  audited (zizmor pedantic: no findings).
* Bad, because the first local run downloads the hook environment and CI downloads all tools
  on every run (~1–2 minutes).
* Making the `lint` check **required** on `main` is part of the rulesets (Étape 7).

### Confirmation

Negative tests on 2026-11-10: a fake token (gitleaks), a private-key header, unformatted
OpenTofu, an unused variable (tflint, confirming the root `.tflint.hcl` is used recursively),
duplicate YAML keys (check-yaml, yamllint), an unpinned action with template injection
(actionlint, zizmor), an unquoted shell variable (shellcheck) and a commit on `main`
(`no-commit-to-branch`) were all rejected. Lockfile enforcement under `MISE_SAFE=1` was
verified with a tampered checksum (install refused).
