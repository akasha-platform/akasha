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

* **One list of checks** in `.pre-commit-config.yaml`, run by pre-commit 4.7. **Every hook is
  `repo: local`** and calls a pinned tool through `mise exec --` / `uv run --locked`, so
  pre-commit itself downloads nothing (no third, unlocked pinning layer):
  * generic hygiene from the `pre-commit-hooks` 6.0.0 package, locked in `uv.lock` together with
    its `ruamel.yaml` dependency (a remote `repo:` entry would make pre-commit pip-install
    `ruamel.yaml>=0.15` without hashes or cooldown): whitespace, end of file, LF line endings,
    YAML/TOML/JSON syntax, merge markers (`--assume-in-merge`, otherwise a no-op outside a
    merge and in CI), case conflicts, large files, shebangs, **private keys**, **no commit to
    `main`**; hook definitions copied from upstream `.pre-commit-hooks.yaml`;
  * pinned tools: gitleaks, tofu fmt, tflint, trivy config with `--skip-check-update` (checks
    embedded in the signed binary, instead of pulling the floating `trivy-checks:2` bundle at
    run time), actionlint, zizmor (offline), shellcheck, yamllint, ansible-lint.
* **Local git hook**: `pre-commit install` (per clone). The `no-commit-to-branch` hook makes
  every change go through a branch and a pull request.
* **CI** (`.github/workflows/lint.yml`) on GitHub-hosted `ubuntu-24.04`, on pull requests,
  pushes to `main` and manual runs:
  * `permissions: {}` at workflow level, `contents: read` for the job; no secrets;
    `actions/checkout` v7.0.1 and `jdx/mise-action` v5.2.6 pinned by full SHA;
    `persist-credentials: false`; `MISE_SAFE=1`; no cache (cache poisoning avoided; revisit if slow);
  * mise `2026.11.1` (oldest release able to read lockfile format v4). The pull request that
    introduces CI was opened on 2026-11-10, when that release was 5 days 20 hours old: a
    recorded exception to the release cooldown (ADR-0022), accepted by the owner because this
    job has no secrets and only a read-only token;
  * steps: `mise install --locked` (by the action), `uv sync --locked`, pre-commit on all files
    (`SKIP=no-commit-to-branch`), gitleaks on the **full history**, zizmor with **online**
    audits using the read-only token;
  * every `run:` step calls its tool through `mise exec --`, because the `ubuntu-24.04` image
    preinstalls other versions (shellcheck 0.9, yamllint, ansible 2.21 — incompatible with
    kolla-ansible 2026.1) that must never win on `PATH`.
* trivy config scans the whole repository (`infra/` and `apps/`, `.venv` skipped) so Dockerfiles
  and charts added in P6 are covered.

### Consequences

* Good, because the same checks and versions run locally and in CI, and the workflow itself is
  audited (zizmor pedantic: no findings).
* Bad, because the first local run downloads the hook environment and CI downloads all tools
  on every run (~1–2 minutes).
* Making the `lint` check **required** on `main` is part of the rulesets (Étape 7).
* When Ansible code arrives (P1), add `.ansible-lint` with `offline: true` so ansible-lint never
  installs collections from the network.

### Confirmation

Negative tests on 2026-11-10: a fake token (gitleaks), a private-key header, unformatted
OpenTofu, an unused variable (tflint, confirming the root `.tflint.hcl` is used recursively),
duplicate YAML keys (check-yaml, yamllint), an unpinned action with template injection
(actionlint, zizmor), an unquoted shell variable (shellcheck) and a commit on `main`
(`no-commit-to-branch`) were all rejected, and so were trailing whitespace, a non-executable
script with a shebang and committed merge markers after the switch to local hooks. After
`pre-commit clean`, a full run initialised no remote environment. Trivy with
`--skip-check-update` and an empty cache still reported HIGH findings and downloaded nothing.
Lockfile enforcement under `MISE_SAFE=1` was verified with a tampered checksum (install refused).
A clean-room run executed the workflow's `run:` steps verbatim (parsed from `lint.yml`, empty
caches, `CI=true`): all exited 0. The CI mise version 2026.11.1 (binary checksum matched the
release `SHASUMS256.txt`) installed all eight tools from the format-v4 `mise.lock`.
