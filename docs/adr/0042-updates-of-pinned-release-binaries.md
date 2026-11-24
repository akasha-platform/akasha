---
status: accepted
date: 2026-11-24
decision-makers: dhuy21
---

# Updates of the release binaries pinned in Ansible roles

## Context and Problem Statement

Two programs on the lab's VMs come from GitHub releases instead of Debian's archive:
* OpenBao on `core` (ADR-0039);
* mise on the bastion (ADR-0040).

Unattended upgrades never patch them. Each one is pinned in its role's defaults by three values:
the version, the SHA-256 of the file, and the release's publication time (the cooldown of
ADR-0022). Step 7 starts storing real secrets in OpenBao, so something has to report new
releases before then (open question B16).

Facts checked on 2026-11-24 in Renovate's documentation (Mend Renovate 44.261.1):
* A regex custom manager (`customManagers`, `customType: regex`) reads versions from any file
  through named capture groups. It has a `datasource`, a `depName` and a `currentValue`.
* The `github-releases` datasource gives release timestamps, so `minimumReleaseAge` can apply
  to it. Without a timestamp, the default `minimumReleaseAgeBehaviour` (`timestamp-required`)
  does not treat a release as stable.
* The documentation describes no way for a regex manager to update a file checksum or a date
  together with the version.

## Decision Drivers

* A new release, a security release above all, must not depend on someone remembering to look.
* Nothing may be installed before its signature is checked by hand (ADR-0039, ADR-0040).
* Keep the 6-day cooldown and the existing Renovate setup (ADR-0024).

## Considered Options

* Watch the releases by hand (GitHub "Watch → Releases"), as the runbooks did.
* **A Renovate regex custom manager on the version lines.** The checksum, the date and the
  signature check stay manual.
* The same, with cosign added to the pinned toolchain, to also check the releases' sigstore
  signatures.

## Decision Outcome

Chosen by the owner on 2026-11-24: **a Renovate regex custom manager**, without cosign.

* **Annotation.** A `# renovate: datasource=github-releases depName=<owner>/<repo>` comment
  sits right above each `*_version` line in `infra/ansible/roles/*/defaults/main.yml`.
* **Extraction.** One custom manager reads those lines; `extractVersionTemplate` turns the
  tag `v2.7.3` into `2.7.3`.
* **Pull requests.** A rule for `custom.regex` adds a note to every such pull request: do not
  merge as it is. First check the signature, then update `*_sha256` and `*_published_at` in
  the same file, following runbook `core.md` (OpenBao) or `bastion.md` (mise).
* **Unchanged from ADR-0024:** the 6-day `minimumReleaseAge`, the Monday schedule, no
  automerge. Security fixes are exempt from the cooldown, as for every other dependency.
* **The role is the last guard.** If a pull request is merged with only the version changed,
  `get_url` rejects the download, because its checksum no longer matches, and the run stops.
  Nothing unverified gets installed.

### Consequences

* Good, because new releases arrive as pull requests, next to every other update.
* Good, because the signature check and the checksum stay a human step, and the role fails
  closed when that step is skipped.
* Bad, because every such pull request needs a manual commit on Renovate's branch before it
  can be merged. Lint CI stays green on a pull request that cannot work, because CI never
  runs the roles.
* Bad, because mise releases often. Under the weekly schedule, the bastion's mise can differ
  from the laptop's, which is not pinned.
* Bad, because the releases' sigstore signatures are still not checked (no cosign).

### Confirmation

* Before the pull request, the manager's patterns were run with Node's regular expressions
  over the repository files. They found exactly `openbao/openbao 2.7.3` and `jdx/mise 2026.11.4`.
* After the merge, the Dependency Dashboard (issue #12) lists both under `regex`, and Renovate
  reports no configuration error.

### Implementation (2026-11-24)

Merged in PR #73. The Dependency Dashboard (#12) listed `openbao/openbao 2.7.3`, with no update,
and `jdx/mise 2026.11.4`, which had an update to 2026.11.10. mise had released 2026.11.11 to
2026.11.14 already, but they were younger than 6 days, so the cooldown applies to this manager.

The CI's mise, the `version:` of `jdx/mise-action`, also has the dependency name `jdx/mise`,
and Renovate put both bumps on the same branch (PR #32). The rule for `custom.regex` therefore
sets `additionalBranchPrefix: pinned-binary-` and its own `commitMessageTopic`. With them,
each pinned binary gets a pull request of its own.

## More Information

* Renovate: regex manager https://docs.renovatebot.com/modules/manager/regex/; GitHub releases
  datasource https://docs.renovatebot.com/modules/datasource/github-releases/;
  `minimumReleaseAge`, `prBodyNotes`, `matchManagers`
  https://docs.renovatebot.com/configuration-options/.
* ADR-0022 (cooldown), ADR-0024 (Renovate), ADR-0039 (OpenBao), ADR-0040 (bastion mise).
