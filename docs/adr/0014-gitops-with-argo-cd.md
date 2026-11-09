---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# GitOps with Argo CD and a separate gitops repository

## Context and Problem Statement

Cluster state must be declarative, reviewable and reproducible after a rebuild.

## Considered Options

* Argo CD · Flux
* CI pushes directly · CI opens PR with new tag · Argo CD Image Updater · Kargo

## Decision Outcome

Chosen option: "Argo CD 3.x" reading `akasha-gitops`, bootstrapped once, then ApplicationSets
for platform components and apps, AppProjects separating platform from apps. CI opens a pull
request in `akasha-gitops` to bump the image digest; promotion dev → prod is a pull request.
Argo CD pulls from GitHub, so no inbound connectivity is required.

### Consequences

* Good, because every deployment is a reviewed commit and rollback is a revert.
* Bad, because cross-repo PRs require a GitHub App or fine-grained token.
