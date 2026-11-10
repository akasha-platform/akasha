---
status: accepted
date: 2026-11-09
decision-makers: dhuy21
---

# Pinned and verified developer toolchain (mise + uv)

## Context and Problem Statement

The project needs ~12 command-line tools (OpenTofu, linters, scanners, Ansible). Unpinned
installs drift between the laptop and CI, and the March 2026 Trivy compromise showed that
"latest" can be malicious. Every tool must be pinned to an exact version, verified by checksum
and, when the publisher provides it, by signature or attestation — identically on the laptop
and in CI.

## Considered Options

* mise (aqua backend) for binaries + uv project for Python tools
* aqua + uv (aqua checksum enforcement is off by default; one more tool)
* asdf (no lockfile, verification depends on plugin scripts)
* devcontainer / Nix / devbox (heavier; a devcontainer may later wrap the chosen approach)

## Decision Outcome

Chosen option: "mise + uv".

* **mise** (installed from the official PPA `ppa:jdxcode/mise`, signed repository;
  `min_version = 2026.11.1` for lockfile format v4) reads `mise.toml` and the committed
  `mise.lock` (version, URL, SHA-256 and provenance per platform). Settings: `locked = true`,
  `locked_verify_provenance = true`, `disable_backends = ["asdf", "vfox"]`; every tool uses an
  explicit `aqua:` backend.
* **uv** project (`pyproject.toml`, `uv.lock` with hashes, `.python-version` 3.14) for
  ansible-core 2.20.x (compatible with kolla-ansible 2026.1 and 2026.2), ansible-lint,
  yamllint and pre-commit (chosen over prek: mature; same config format if switched later).
* **7-day rule:** pin the newest release published at least 7 days earlier. For PyPI this is a
  fixed `exclude-newer` timestamp, moved forward deliberately.
* System-wide Terraform/Ansible on the laptop are left untouched; mise and uv only apply
  inside the repository.

Verification level at first lock (2026-11-09):

| Tool | Version | Verification |
|---|---|---|
| trivy | 0.76.1 | cosign (by mise) |
| uv, actionlint, tflint, zizmor | 0.13.6, 1.7.12, 0.65.0, 1.32.0 | GitHub attestations (by mise) |
| OpenTofu | 1.13.2 | checksum in lock; **manually** verified with `cosign verify-blob` against the identity published by OpenTofu (`release.yml@refs/heads/v1.13`) and the official SHA256SUMS |
| gitleaks | 8.30.1 | checksum in lock = official `checksums.txt` (no publisher signature) |
| shellcheck | 0.11.0 | checksum in lock = GitHub asset (no publisher signature or checksum file: trust on first use) |

### Consequences

* Good, because laptop and CI resolve byte-identical tools and refuse tampered downloads.
* Bad, because updates need a deliberate re-lock and, for unsigned tools, a manual check.
* OpenTofu must be bumped to ≥ 1.13.9 (fixes a local-state persistence bug on a crashed first
  apply and a panic on invalid state-encryption config) before the first apply in P1.
* Whether Renovate can refresh `mise.lock` and which component owns the cooldown are decided
  in Étape 6 (`docs/open-questions.md` B9).

## More Information

How-to: [docs/development.md](../development.md).
