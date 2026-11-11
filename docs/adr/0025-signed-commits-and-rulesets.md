---
status: accepted
date: 2026-11-11
decision-makers: dhuy21
---

# Signed commits and repository rulesets protecting `main`

## Context and Problem Statement

Until now `main` was protected only by the local `no-commit-to-branch` hook, which anyone can
skip. Anyone can also set any name and e-mail in a commit, so authorship was not provable. The
server must enforce the review path (pull request, green `lint`, squash) and accept only signed
commits, without locking out the single owner (who cannot approve their own pull requests).

## Considered Options

* Repository rulesets (available for public repositories on GitHub Free) + SSH commit signing
* Organization rulesets (refused on GitHub Free: "Upgrade to GitHub Team", verified via the API)
* Classic branch protection (older model; rulesets are layered, auditable and also cover tags)
* GPG signing (heavier key management than SSH, same verification on GitHub)

## Decision Outcome

Chosen option: "Repository rulesets + SSH commit signing".

* **Signing**: a dedicated ed25519 key (`~/.ssh/id_ed25519_signing`, with a passphrase, loaded
  in ssh-agent), registered on GitHub as a *Signing key* and separate from the authentication
  key; global git config `gpg.format=ssh`, `commit.gpgsign=true`, `tag.gpgsign=true` and an
  `allowed_signers` file for local verification (setup in `docs/development.md`). The committer
  e-mail is a verified address of the account. Renovate commits and GitHub squash merges are
  signed by GitHub.
* **Ruleset `main`** on `akasha` (target `~DEFAULT_BRANCH`, active, **no bypass actors**):
  * pull request required, 0 approvals (an author cannot approve their own pull request),
    review threads must be resolved, **squash only**;
  * required status check `lint` from GitHub Actions (integration 15368), branch must be up to
    date (Renovate rebases its own pull requests);
  * signed commits required (every commit of a pull request, not only the squash result),
    linear history, no force push, no deletion.
* **Ruleset `main`** on `akasha-gitops`: the same, without a required status check (no workflow
  yet; add `lint` when CI exists there).
* **Ruleset `release tags`** on `akasha` (`refs/tags/v*`): no deletion, no update, no force push.
* **Emergency procedure**: nobody can bypass; the owner (repository admin) switches the ruleset
  enforcement to `disabled`, fixes, and re-enables it. The change is recorded in the ruleset
  history.
* `renovate/stability-days` is **not** required: only Renovate posts it, so it would block every
  human pull request.
* Vigilant mode (flag unsigned commits as unverified) is left off for now: history before
  2026-11-11 contains unsigned commits.

### Consequences

* Good, because every change on `main` is reviewed through a pull request, passes `lint` and is
  signed, even if the local hook is skipped.
* Good, because a lost or stolen signing key is revoked on its own, without touching SSH access.
* Bad, because a pull request with one unsigned commit cannot be merged until its commits are
  re-signed (`git rebase --exec 'git commit --amend --no-edit -S' main`, then force-push the
  branch).
* Bad, because GitHub's "Update branch" in rebase mode would produce unsigned commits; use the
  merge mode or rebase locally.

### Confirmation

On 2026-11-11, with the rulesets active:

* `GET /repos/akasha-platform/{akasha,akasha-gitops}/rules/branches/main` lists the expected
  rules, and `current_user_can_bypass` is `never` on all three rulesets.
* A signed commit pushed from the laptop shows `verified=true` on GitHub.
* Test pull request #16, with `lint` green: an unsigned commit made it `BLOCKED` ("the base
  branch policy prohibits the merge"); the same commit re-signed made it `CLEAN`; a signed
  commit failing `lint` made it `BLOCKED` again. Closed without merging.
