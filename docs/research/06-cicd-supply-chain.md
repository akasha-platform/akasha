# 06 — CI/CD and supply chain

Researched: 2026-11-08. Re-check versions and GitHub features before use. Tool versions are not pinned in this note on purpose; Renovate keeps them current.

## Self-hosted runners and public repositories

- GitHub says self-hosted runners "should almost never be used for public repositories" because they "can be persistently compromised". Environments with required reviewers protect secrets, but self-hosted jobs "are not run in an isolated environment". **VERIFIED**: https://docs.github.com/en/actions/reference/security/secure-use
- A fork PR can edit the workflow YAML, including `runs-on`. Trigger filters written in our own YAML therefore protect nothing. Only repository/org settings and runner scoping do. **INFERRED**
- akasha's mitigations:
  - org setting **"require approval for all external contributors"** (applied in Étape 1);
  - runner groups, which require an org;
  - self-hosted runners only on `push`/tags;
  - **never `pull_request_target`**;
  - ephemeral runners;
  - default-deny egress.

## Actions Runner Controller (ARC)

- The GitHub-supported mode is **runner scale sets**, installed from the charts `gha-runner-scale-set-controller` and `gha-runner-scale-set`. The older summerwind CRDs are community-supported. **VERIFIED**: https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets
- Latest is **0.15.1** (2026-10-23). The "experimental" charts are not for production. **VERIFIED**: https://github.com/actions/actions-runner-controller/releases
- Container modes **VERIFIED**: same docs page.

| Mode | Requirement / risk |
|---|---|
| `dind` | Needs a privileged container |
| `kubernetes` | Pod per job plus an RWO PVC; risk of API-server privileges if a job has no job container |
| `kubernetes-novolume` | Since 0.13; no shared PVC |

- The self-hosted runner platform fee announced for March 2026 was postponed. Its status in Nov 2026 is **unverified**: https://resources.github.com/actions/2026-pricing-changes-for-github-actions/

## Building images without a Docker daemon

- **Kaniko** was archived in June 2025. Chainguard's fork only gets maintenance and publishes no free images. **VERIFIED**: https://github.com/chainguard-dev/kaniko
- **BuildKit rootless** needs Unconfined seccomp and AppArmor, and does not work with Kubernetes user namespaces. **VERIFIED**: https://kubernetes.web.cern.ch/blog/2025/06/19/rootless-container-builds-on-kubernetes/
- **Buildah** rootless works with the vfs driver (same CERN source).
- **Choice:** BuildKit rootless on a tainted CI node, inside a PSA-privileged namespace guarded by Kyverno. See [05](05-kubernetes-on-openstack.md). **INFERRED**
- **Runner ↔ BuildKit wiring:** ARC runners stay in the default container mode (no Docker daemon, no privileges). A separate rootless `buildkitd` Deployment runs in the build namespace, and jobs reach it with `docker buildx create --driver remote tcp://buildkitd.<ns>:1234`. No official ARC document recommends a builder, so this is **INFERRED** from the ARC and BuildKit docs above.

## Registry

- **GHCR** has no infrastructure to run, uses `GITHUB_TOKEN` auth, is free for public packages and works natively with attestations. This is the choice.
- **Harbor** 2.14/2.15 offers scanning, immutability and replication, but it is stateful infrastructure. **VERIFIED**: https://endoflife.date/harbor

## GitOps

- **Argo CD v3.6.1** (2026-11-04); 3.3 reached EOL on 2026-11-03. **VERIFIED**: https://github.com/argoproj/argo-cd/releases
- **Flux v2.10** (2026-10-26). **VERIFIED**: https://fluxcd.io/blog/
- **Argo CD Image Updater v1.x** is CRD-based. **Kargo v1.12.5** handles promotion. **VERIFIED**: https://github.com/argoproj-labs/argocd-image-updater/releases , https://github.com/akuity/kargo/releases
- **Pattern chosen:** two repos (app/infra and gitops).
  - CI opens a PR in the gitops repo to bump the image tag or digest. This is the simplest and most auditable option. **INFERRED** (common practice)
  - App-of-Apps is "an admin-only tool". Bootstrapping should use ApplicationSets. **VERIFIED**: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
  - Three layers (manifests → ApplicationSets → root app). **VERIFIED**: https://codefresh.io/blog/how-to-structure-your-argo-cd-repositories-using-application-sets
- **GitOps Bridge** (Terraform writes cluster metadata as labels/annotations on the Argo CD cluster Secret, ApplicationSets read it) exists, **VERIFIED**: https://github.com/gitops-bridge-dev/gitops-bridge. Akuity criticises it for splitting configuration between Git and live Secrets, **VERIFIED**: https://akuity.io/blog/yet-another-take-on-integrating-terraform-with-argo-cd. Not adopted for now.
- **Bitnami** free images were withdrawn in Aug–Sep 2025, so avoid Bitnami charts and images. **VERIFIED**: https://github.com/bitnami/charts/issues/35164

**Proposed `akasha-gitops` layout** (**INFERRED**, synthesised from the Argo CD and Codefresh sources above):

```
bootstrap/root-app.yaml            # applied once (by Ansible/OpenTofu in L3/L4)
appsets/{platform.yaml,apps.yaml}  # git-directory generators
platform/<component>/{base/,envs/dev/,envs/prod/}
apps/novashop/envs/{dev,prod}/values.yaml   # image digest bumped by CI PR
projects/                          # AppProjects: platform vs apps
```

Image bumps: the release workflow opens the PR in `akasha-gitops` with a GitHub App token (or fine-grained token) scoped to that repository only. **INFERRED**

## Trivy compromise, March 2026 (CVE-2026-33634)

- **What happened:** on 2026-03-19 the attacker force-pushed 75 of 76 `trivy-action` tags and all 7 `setup-trivy` tags, and published a malicious v0.69.4 binary. Malicious images 0.69.5 and 0.69.6 followed. tfsec and kics-github-action were also hit.
- **Root cause:** the attacker kept access after incomplete containment of an earlier incident that started with `pull_request_target`.
- **VERIFIED**: https://wiz.io/blog/trivy-compromised-teampcp-supply-chain-attack , https://www.legitsecurity.com/blog/the-trivy-supply-chain-compromise-what-happened-and-playbooks-to-respond

**Lessons applied in akasha:**
1. Pin every action by **full commit SHA**. The org policy `sha_pinning_required` is enabled (Étape 1). **VERIFIED**: https://github.blog/changelog/2025-08-15-github-actions-policy-now-supports-blocking-and-sha-pinning-actions/
2. Run scanners in jobs with no secrets and a read-only `GITHUB_TOKEN`.
3. Never use `pull_request_target`.
4. Pin scanner binaries by checksum or digest, and delay updates with Renovate `minimumReleaseAge`.
5. Enable immutable releases on our own repos. **VERIFIED**: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
6. Workflow lockfiles (`actions.lock`) are in public preview since 2026-10-14; plan coverage is unclear. **VERIFIED**: https://github.blog/changelog/2026-10-14-github-actions-workflow-lockfiles-in-public-preview/

## Static checks and dependency updates

- **pre-commit:** `antonbabenko/pre-commit-terraform` provides fmt, validate, tflint, `terraform_trivy` and checkov (the old tfsec hook is deprecated). **VERIFIED**: https://github.com/antonbabenko/pre-commit-terraform
  - Also: ansible-lint, yamllint, shellcheck, `helm lint` plus kubeconform, and gitleaks.
- **zizmor** audits GitHub Actions for template injection, excessive permissions, unpinned uses and `pull_request_target`. Its hook also works with **prek** (a Rust rewrite of pre-commit). **VERIFIED**: https://docs.zizmor.sh/integrations/
- **SBOM and second scanner:** Syft (SBOM) and Grype (vulnerabilities) from Anchore are the usual complements to Trivy. **INFERRED** (no primary source checked for current versions): https://github.com/anchore/syft , https://github.com/anchore/grype

**Full CI stage list** (common practice, **INFERRED**; tool versions pinned by Renovate):

| Area | Stages |
|---|---|
| All | pre-commit (`pre-commit run --all-files`), gitleaks, yamllint, shellcheck, zizmor |
| OpenTofu | `tofu fmt -check`, `tofu validate`, tflint, `trivy config` (or checkov), `plan` on PR, gated `apply` |
| Ansible | ansible-lint, `ansible-playbook --syntax-check`, Molecule (optional) |
| Helm / manifests | `helm lint`, `ct lint` (chart-testing), kubeconform on rendered output, optional Kyverno CLI tests |
| App (NovaShop) | ruff, pytest, image build, Trivy/Grype scan, Syft SBOM, cosign sign + attest, push by digest, PR to `akasha-gitops` |
| Dependencies | Renovate (incl. SHA-pinned actions, `minimumReleaseAge`) |
- **Renovate:**
  - Terraform lock-file maintenance. **VERIFIED**: https://docs.renovatebot.com/modules/manager/terraform/
  - `helpers:pinGitHubActionDigests`. **VERIFIED**: https://docs.renovatebot.com/modules/manager/github-actions
  - Argo CD manager needs `managerFilePatterns`. **VERIFIED**: https://docs.renovatebot.com/modules/manager/argocd/
  - `minimumReleaseAge` 3–7 days with `internalChecksFilter: strict`. **VERIFIED**: https://docs.renovatebot.com/key-concepts/minimum-release-age/

## CI for private infrastructure from a public repository

- **Infrastructure jobs** (OpenTofu, Ansible, Kolla) run on a **GitHub-hosted runner joined to the tailnet** with `tailscale/github-action` and workload identity federation (`id-token: write`). That gives an ephemeral node that may reach only the bastion's SSH port through ACL tag `tag:ci`. **VERIFIED**: https://tailscale.com/kb/1276/github-action
  - Plan on PR; apply on merge to `main` or manual dispatch through a protected environment. Serialise applies with a `concurrency` group.
- **Alternatives:**
  - Atlantis (CNCF Sandbox, v0.49.0) needs inbound webhooks. **VERIFIED**: https://github.com/runatlantis/atlantis/releases
  - Digger/OpenTaco runs inside Actions. **VERIFIED** (secondary): https://github.com/diggerhq/digger
  - HCP Terraform's free tier is capped at 500 resources. **VERIFIED**: https://www.hashicorp.com/blog/continuing-hcp-terraform-s-enhanced-free-tier-experience
- **Secrets:** use OIDC to OpenBao. JWT auth with `bound_claims`; prefer `repository_id` and bind `environment`/`ref`. **VERIFIED**: https://openbao.org/docs/auth/jwt/ , https://docs.github.com/en/actions/reference/security/oidc
- **Attestations:** `actions/attest` gives SLSA v1.0 Build L2, free for public repos (Sigstore public-good). **SLSA Build L3 requires reusable workflows.** **VERIFIED**: https://github.com/actions/attest-build-provenance
- **Signing:** cosign v3 defaults to the bundle format and keyless signing. **VERIFIED**: https://blog.sigstore.dev/cosign-3-0-available/
- **Deploy-time verification and policies:** Kyverno is a CNCF graduated project. Kyverno 1.19 deprecates `ClusterPolicy`, so **new policies are written as `ValidatingPolicy` / `ImageValidatingPolicy`** (the latter verifies keyless signatures and attestations). **VERIFIED**: https://kyverno.io/blog/2026/08/20/announcing-kyverno-release-1.19
- **Serialising applies:** a GitHub Actions `concurrency` group per stack prevents two applies at once (complements state locking). **INFERRED**

## Process for a solo developer imitating a team

- **Rulesets** rather than classic branch protection:
  - require a PR with **0 approvals** (it still blocks direct pushes), status checks, linear history and signed commits;
  - bypass only through PRs.
  - **VERIFIED**: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- **Commits and ownership:** Conventional Commits, SSH-signed commits, CODEOWNERS. **INFERRED**
- **Releases:** release-please in manifest mode, with the `helm` release type for the chart (updates `Chart.yaml` and `CHANGELOG.md`), a language type for NovaShop, and `extra-files` to keep `appVersion` in sync. **VERIFIED**: https://github.com/googleapis/release-please/blob/main/docs/customizing.md
- **Decision records:**
  - **MADR 4.0.0**. **VERIFIED**: https://github.com/adr/madr
  - log4brains is stale (last release 2024-12), so use plain Markdown. **VERIFIED**: https://packages.ecosyste.ms/api/v1/registries/npmjs.org/packages/@log4brains%2Fcli
- **Diagrams and docs:** Mermaid for diagrams; Structurizr only for real C4 models. **VERIFIED**: https://docs.structurizr.com/ai
- **Postmortems:** Google SRE template. **VERIFIED**: https://sre.google/sre-book/example-postmortem/
- **Infrastructure layout:** small root modules with one state per layer ("ideally only a few dozen" resources per state). **VERIFIED**: https://docs.cloud.google.com/docs/terraform/best-practices/root-modules
  - Terragrunt 1.0 shipped 2026-03-30; adopt it only if boilerplate hurts. **VERIFIED**: https://gruntwork.io/blog/the-road-to-terragrunt-1-0-stacks

**Proposed `akasha` layout** (**INFERRED**, synthesised from the sources above; the `terraform/` vs `tofu/` folder naming is decided in Étape 3):

```
infra/
  terraform/
    modules/                  # libvirt_vm, os_network, os_project, k8s_node…
    live/
      l0-host/                # base image, OPNsense, bastion, core (host bridges/nftables are Ansible)
      l1-openstack-vms/       # os-ctl01, os-cmp01, os-cmp02
      l2-openstack-resources/ # projects, networks, images, flavors, app credentials
      l3-k8s/                 # K3s VMs (openstack provider)
  ansible/{inventories,playbooks,roles,collections}
  kolla/                      # globals.d/, config/, inventory (passwords from OpenBao)
apps/novashop/{src/,Dockerfile,chart/}
docs/{adr,architecture,research,runbooks,postmortems,slo}
.github/{workflows/,CODEOWNERS,ISSUE_TEMPLATE/}
```

**Repository files and documentation conventions** (**INFERRED** unless noted):
- **LICENSE:** Apache-2.0 recommended for infra code (explicit patent grant); MIT also acceptable. **ESTIMATED** (judgement).
- **SECURITY.md:** state that the lab is not Internet-exposed, what is in scope, and how to report a problem privately.
- **README structure:** one-paragraph pitch, architecture diagram, layer table, tech stack, "reproduce it" section, roadmap/status table.
- **Docs structure:** a trimmed arc42 (https://arc42.org) organised Diátaxis-style (https://diataxis.fr); khuedoan/homelab uses Diátaxis. **VERIFIED** (references exist).
- **Runbook format:** Symptom → Impact → Diagnosis commands → Mitigation → Escalation/rollback → Links; one runbook per alert.
- **SLOs:** availability and latency SLIs for NovaShop over a 30-day window, with an error-budget policy modelled on https://sre.google/workbook/error-budget-policy/.
- **Definition of Done per phase** (each phase adds its own criteria, e.g. "`just l0-up` rebuilds from zero", "recreate cluster → platform converges with no manual step"). **Shared DoD for every phase:** merged through a PR, ADR written or superseded, diagram/README updated, runbook for new failure modes, changelog entry.
- **GitHub Projects:** one milestone per phase; labels `layer/L0` … `layer/L5` and `type/feat|chore|docs|incident`; an issue per ADR.

**Reference repositories** (all **VERIFIED**):

| Repository | Notable for |
|---|---|
| https://github.com/onedr0p/home-ops | Flux, Talos, Renovate everywhere, ARC in-cluster, SECURITY/CONTRIBUTING files |
| https://github.com/khuedoan/homelab | OpenTofu + Terragrunt, Argo CD, OpenBao, Diátaxis docs, staging/prod |
| https://github.com/ricsanfre/pi-cluster | Ansible + OpenTofu + Flux, runbooks, a "deprecated technology" page |
