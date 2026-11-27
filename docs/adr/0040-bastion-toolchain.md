---
status: accepted
date: 2026-11-24
decision-makers: dhuy21
---

# Toolchain of the bastion: pinned mise, the repository at one commit, an unprivileged user

## Context and Problem Statement

The bastion will run tools inside the lab:
* Kolla-Ansible and Ansible against the OpenStack VMs (P2);
* `tofu` for CI behind a forced-command wrapper (P3, ADR-0032).

It needs the toolchain the laptop and CI use (ADR-0022): mise with `mise.toml` and `mise.lock`,
and uv with `pyproject.toml` and `uv.lock`. Several points were open:
* how mise itself is installed;
* how the code reaches the bastion;
* which user runs the tools;
* how the bastion reaches the other VMs.

Facts checked on 2026-11-24:

* **mise's apt repository** (`https://mise.jdx.dev/deb`) serves only its latest release:
  `2026.11.14`, published that morning (2026-11-24T11:00Z). It therefore offers no pin and
  no cooldown. The laptop runs `2026.11.4`, published 2026-11-07.
* **mise's GitHub releases** publish, for each version, a `linux-x64` binary and a
  `SHASUMS256.asc`. For 2026.11.4, that file carries a valid GPG signature by key
  `2485 3EC9 F655 CE80 B48E 6C3A 8B81 C9D1 7413 A06D` ("mise releases"), whose fingerprint
  `https://mise.jdx.dev/installing-mise.html` publishes. The signed checksum of the binary
  is `0296d9cb…bb8ddc2b`. VERIFIED.
* **The install, run by hand** in a Debian 13 container (2026-11-24):
  * git cloned the repository at `c26ccc4`, then `mise install` installed the 9 locked tools
    in 10 s with provenance checks;
  * `uv sync --locked` installed the environment, and the pinned collections installed;
  * a second run of each changed nothing, and the user had no sudo.

  The rate limit of GitHub's API was not hit from the laptop's network. Lab traffic leaves
  through the campus NAT, whose address is shared, so the unauthenticated limit (60 requests
  an hour) may be hit there (INFERRED; it fails closed).
* **The role, run through Ansible** against a container with the cloud image's package set
  (no `acl`, no `git`): the independent review found two defects that the run by hand had
  missed. After the fix, the dry run passed, the first run reported `changed=9`, and the second
  run and a later dry run reported `changed=0`.
  * A file template run as the unprivileged user needs the `acl` package.
  * `ansible-galaxy` refuses the play's `LC_ALL=C`.

## Decision Drivers

* Exactly the pinned tools, as on the laptop and in CI (ADR-0022), and the 6-day cooldown.
* A broken tool or playbook must not become root on the bastion. The bastion is the most
  exposed VM (ADR-0011).
* No credential stored on the bastion before it is needed.

## Considered Options

* **mise:** the apt repository, or the pinned GitHub binary.
* **Code:** `git clone` over HTTPS of the public repository at one commit, or `rsync` from the
  laptop.
* **SSH from the bastion to the other VMs:** a key of its own now, agent forwarding, or
  defer to P2.
* **User:** `debian` (passwordless sudo), or a dedicated user without sudo.

## Decision Outcome

Chosen by the owner on 2026-11-24:
* the pinned GitHub binary. The owner first chose the apt repository, then the binary once
  the repository was found unable to pin;
* `git clone` over HTTPS;
* SSH from the bastion deferred to P2;
* a dedicated user, `akasha`, without sudo.

The Ansible role `bastion_toolchain` does the following.

* **User.** It creates `akasha` without password or sudo. The operator reaches it with
  `sudo -iu akasha` from `debian`.
* **mise.** It installs the pinned binary at `/usr/local/bin/mise`, owned by root. The
  binary is accepted only when its SHA-256 matches, and only when the release is past the
  cooldown. Because `akasha` cannot replace it, `mise self-update` fails, and the system
  binary changes only through the role. `akasha` could still run another mise it downloads
  into its own home.
* **Code.** As `akasha`, it checks out `https://github.com/akasha-platform/akasha.git`
  (no credential) at `bastion_toolchain_commit`, `main` by default.
  * The run prints the commit, to compare with GitHub.
  * Local changes to tracked files are never discarded (`force: false`). Untracked files do
    not stop it.
  * The repository is named in `trusted_config_paths` of `/etc/mise/config.toml`, written by
    root, so nothing is written as `akasha` by file transfer. mise 2026.11.4 also trusts the
    active config of `mise install` and `mise exec` on its own (`implicitly_trusts_active_config`,
    VERIFIED in its source by the review). The setting only makes it explicit.
* **Tools.** As `akasha`, in the repository, with `LC_ALL=C.UTF-8`: `mise install` (with
  `locked` and `locked_verify_provenance` from `mise.toml`), `mise exec -- uv sync --locked`,
  and the pinned Ansible collections (ADR-0026).
* **Checks.** A failing command stops the check instead of reading as a pass.
  * `akasha` has no sudo, and mise is the pinned version.
  * Nothing of `mise.lock` is missing (`mise ls --missing`), and the environment matches
    `uv.lock` (`uv sync --locked --check`).
  * The commit is a full SHA, equal to the requested one when a SHA was given.
  * No tracked file is modified.
* **Host firewall.** The bastion gets `vm_firewall` with its defaults (ADR-0039): SSH only
  from itself and the tailnet. Nothing listens on it but sshd.

### Consequences

* Good, because the bastion runs exactly the pinned tools, under a user that cannot become
  root.
* Good, because no credential exists on the bastion yet. Code comes over HTTPS from a public
  repository.
* Bad, because mise is outside Debian's archive, like OpenBao: it is bumped by hand, verified
  as in runbook `bastion.md` (ADR-0042 covers both).
* Bad, because the bastion trusts GitHub's TLS for the code. A commit signature proves
  nothing for squash merges, which GitHub's own key signs (ADR-0032). The operator compares
  the printed commit with GitHub.
* Bad, because the bastion cannot run anything against the other VMs until P2 decides how it
  authenticates (its own key, or certificates from OpenBao's SSH CA after step 7).
* For P3 (CI wrapper, ADR-0032):
  * mise trusts the active config of `mise exec` on its own, so a wrapper running mise in a
    checkout it did not write would trust that checkout's `[env]` and hooks. Consider
    `paranoid = true` in `/etc/mise/config.toml` (not tested).
  * `akasha`'s home is 0700, so the CI user cannot reuse its toolchain and needs its own.

### Confirmation

Step 6c-3, on the bastion:
* every check of the role passes, and a second run reports `changed=0`;
* as `akasha`, `cd ~/akasha/infra/ansible && mise exec -- uv run --locked ansible-playbook
  playbooks/router.yml --syntax-check` succeeds.

### Implementation (2026-11-24)

Applied to the bastion from PR #70.
* **Runs.** The dry run passed. The first run reported `changed=19` (firewall loaded commit
  confirmed, user, mise, checkout, tools, collections), with no GitHub rate limit, and a
  second run reported `changed=0`.
* **The checkout.** It is at `c26ccc4`, the head of `main` on GitHub (`git ls-remote`).
* **Tools.** OpenTofu v1.13.9, uv 0.13.7 and ansible-core 2.20.10, as on the laptop.
* **Access.** `akasha` is not allowed to run sudo, and SSH to the bastion is accepted from
  10.10.0.10 and 10.255.255.1 only.
* **Confirmation.** As `akasha`, the syntax check of `router.yml` succeeded.

## More Information

* ADR-0022 (pinned toolchain), ADR-0026 (Ansible), ADR-0032 (CI through the bastion),
  ADR-0039 (host firewall defaults).

## Updates

* 2026-11-24: Renovate now opens a pull request when a new release of mise is out, through a
  regex custom manager on the version line ([ADR-0042](0042-updates-of-pinned-release-binaries.md),
  open question B16). The SHA-256, the publication time and the signature check stay manual.
* 2026-11-27: SSH from the bastion to the OpenStack nodes, deferred here, is decided in
  [ADR-0050](0050-bastion-ssh-certificates-from-openbao.md): `akasha`'s key, signed by OpenBao's
  SSH CA for 8 hours, and the nodes' host keys copied from the laptop (role `bastion_ssh`).
