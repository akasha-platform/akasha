# CLAUDE.md — working context for akasha

akasha grows a school exercise (TD2: Terraform → Ansible → Helm deploying the
3-tier "NovaShop" app on K3s/OpenStack) into a production-grade private cloud
and Kubernetes platform, built on one school-provided physical host.

## Read first

- `docs/roadmap.md` — phases, étapes and their status. Work resumes from here.
- `docs/open-questions.md` — pending tests, deferred decisions and questions never discussed yet.
  Check it before planning an étape; ask the owner instead of deciding these alone.
- `docs/architecture/overview.md` — the target design (layers L0–L5, nodes, networks, RAM/disk budgets).
- `docs/adr/` — every architectural decision with context, options and rationale.
- `docs/research/` — the sourced research behind the decisions (re-check versions/prices before use).

## How the owner wants to work

- Implement **one étape at a time**. Present the plan of the étape in this order: goal, why,
  exact actions, **blast radius**, **what can go wrong**, verification, rollback (ADR-0027).
  Wait for approval, execute, verify, then ask for validation before starting the next étape.
  Never bundle étapes.
- **Blast radius**: one row per action — action · touches · owner of it · what else depends
  on it · effect if it fails · rollback. A row not owned by akasha is a question for the owner.
- **What can go wrong**: unverified assumptions (tagged INFERRED) and failure modes
  (fail-open/fail-closed, lockout, effect on other services). Check a tool's behaviour in its
  docs or source before stating it as fact.
- Plans that change the network, disks, firewall or boot of `insa`, and every irreversible
  action, get an **independent review** by a subagent first: give it the plan and the code,
  not your reasoning or conclusions; show its findings to the owner with the plan.
- Ask clarifying questions whenever context is ambiguous instead of assuming.
  Use multiple-choice questions. Conversation language: Vietnamese.
- Research seriously before deciding: official docs and source code first,
  tag claims VERIFIED / INFERRED / ESTIMATED, cite URLs.
- Irreversible actions (deleting VMs, partitioning disks, transferring repos,
  force-pushes) need explicit confirmation inside the étape.
- Propose every architecture change individually (options, recommendation, how professional
  teams do it) and wait for the owner's choice — even inside an approved étape.
- Claude has **no direct access** to the host or the lab. Give the owner explicit command blocks
  (read-only unless the étape says otherwise), then verify the pasted output — and anything
  checkable independently (e.g. GitHub API) — before moving on.
- Every decision that changes the design gets an ADR (MADR 4.0) in `docs/adr/`.

## akasha is a guest on `insa` (ADR-0027)

`insa` is lent by the school; it also runs the school's desktop, a campus NFS mount, possibly
the school's IT management, and the owner's VM `linux2024`. akasha touches only what it owns:
the nft table `inet akasha`, units `akasha-*`, files named `akasha`, bridges `br-*`,
`vg_akasha`, `/var/lib/libvirt/akasha`, and the lab's libvirt domains. Never change host-wide
policy or anything of the school or of `linux2024`; firewall rules match `br-*` or lab
ranges only; akasha opens no listening service on `eno1`. Anything else is the owner's call.

## Public-repo hygiene (this repository is PUBLIC)

Never commit:
- the host's Tailscale address, the campus LAN range, the campus NFS address;
- secrets of any kind (keys, tokens, `passwords.yml` in clear, OpenBao unseal
  shares, restic passwords, kubeconfigs, tfstate).

Allowed: lab-internal 10.x ranges, hardware specs, the fact that the host is
school-provided. Use placeholders such as `<host-tailscale-ip>` when needed.

## Repository conventions

- Docs and code comments in English.
- Toolchain is pinned (ADR-0022): run binaries through mise (`mise exec -- <tool>` or an
  activated shell) and Python tools with `uv run`; never install project tools globally.
  New versions follow the 6-day release cooldown and are re-locked (`mise lock`, `uv lock`).
- Every change goes through a branch and a pull request reviewed by the owner, then a squash
  merge. Commit messages follow Conventional Commits.
- Commits keep the owner's current git identity (owner's choice); never add or change it.
- Commits are signed (SSH, ADR-0025): `main` refuses pull requests with unsigned commits.
- No AI attribution: never add `Co-Authored-By` trailers or "Generated with …" lines to commit
  messages or pull request descriptions (owner's choice).
- GitHub org: `akasha-platform`; repos `akasha` (infra + app + CI) and
  `akasha-gitops` (Argo CD desired state).
- Org Actions policy: actions pinned by full SHA, read-only `GITHUB_TOKEN`,
  fork-PR workflows require approval. Never use `pull_request_target`.
