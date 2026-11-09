---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# GitHub organization and two repositories

## Context and Problem Statement

The project is public (portfolio) and will use self-hosted runners and GitOps. A personal
account cannot restrict self-hosted runners with runner groups, and mixing desired cluster
state with source code makes CI loops and access control harder.

## Decision Drivers

* Safe use of self-hosted runners with a public repository
* Clear separation between "what we build" and "what runs"
* Organization-wide Actions policies

## Considered Options

* Personal account, one repository
* Organization with one monorepo (gitops folder inside)
* Organization with two repositories: `akasha` and `akasha-gitops`

## Decision Outcome

Chosen option: "Organization `akasha-platform` with two repositories", because it enables
runner groups and org policies, and matches the common app-repo / config-repo GitOps split.

* `akasha` — infrastructure code, application source, CI.
* `akasha-gitops` — Argo CD desired state; CI opens pull requests here to bump image versions.

Org settings applied (Étape 1): actions must be pinned to a full commit SHA, default
`GITHUB_TOKEN` is read-only, Actions cannot approve pull requests, fork-PR workflows need
approval for all external contributors, members must use secure 2FA methods only.

Repository settings applied to both repositories (2026-11-09): secret scanning and push
protection enabled (free for public repositories — verified by enabling them), private
vulnerability reporting enabled, squash merge only (commit title = PR title, body = PR body),
head branches deleted on merge, wiki disabled (`docs/` is the single source of truth).
Dependabot security updates are left as they are until Renovate is introduced (Étape 6).

### Consequences

* Good, because policies are enforced centrally and audited via the API.
* Good, because image promotion is a reviewable pull request in `akasha-gitops`.
* Bad, because cross-repository automation needs a scoped token or GitHub App.
* Never create a repository named `akasha` under the former personal account: GitHub would
  permanently delete the redirects left by the transfer.
* `allowed_actions` deliberately stays `all` until Étape 6 restricts it to a selected list.
  `akasha-gitops` was created public, with a README and the wiki disabled.

### Confirmation

`gh api orgs/akasha-platform/actions/permissions` and related endpoints return the settings
above; `two_factor_requirement_enabled` is `true`; `gh api repos/akasha-platform/<repo>` shows
`has_wiki: false`, only `allow_squash_merge: true`, `delete_branch_on_merge: true` and
`secret_scanning` / `secret_scanning_push_protection` enabled.

Note: the public Git history contains the throw-away TD2 lab passwords (documented in the TD2
README). That lab is being destroyed and those values are never reused.
