---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# CI/CD security model for a public repository

## Context and Problem Statement

The repositories are public, the lab is behind NAT, and CI must apply infrastructure changes
and build images. GitHub warns that self-hosted runners "should almost never be used for
public repositories": a fork PR can rewrite `runs-on`.

## Decision Outcome

* **Infrastructure** (OpenTofu, Ansible, Kolla): GitHub-hosted runners join Tailscale with
  `tailscale/github-action` workload identity (ephemeral node, tag-restricted to the bastion's
  SSH). `plan` only on pull requests from branches of this repository — fork PRs get no OIDC
  identity and never reach Tailscale; the identity is bound to the repository and to the
  protected environment. `apply` after merge through that environment.
* **Application builds**: ARC runner scale sets (0.15.x) inside K3s, only for `push`/tag
  events, ephemeral runners, dedicated namespace and tainted node, no service-account token,
  egress NetworkPolicy (blocks node subnet and the metadata endpoint 169.254.169.254).
  Pull-request CI runs on GitHub-hosted runners.
* **Supply chain**: every action pinned by full SHA (org policy), Renovate with
  `minimumReleaseAge`, zizmor for workflows, never `pull_request_target`, scanners run without
  secrets, cosign keyless signing and GitHub artifact attestations, images in GHCR.
  Lessons from the March 2026 Trivy compromise (CVE-2026-33634).
* **Process**: rulesets on `main` (PR required, `lint` required, signed commits, squash only;
  ADR-0025), Conventional Commits, release-please (later). Every change goes through a pull
  request reviewed by the owner and is squash-merged. GHCR as the registry and
  Conventional Commits + release-please were confirmed explicitly by the owner on 2026-11-09.

### Consequences

* Good, because no inbound access to the lab is needed and no long-lived CI secrets exist.
* Bad, because CI runners share the cluster with production workloads (residual risk documented).

## More Information

[research/06-cicd-supply-chain.md](../research/06-cicd-supply-chain.md)
