---
status: accepted
date: 2026-11-18
decision-makers: dhuy21
---

# CI-applied OpenTofu states in AWS S3, applied from the bastion

## Context and Problem Statement

ADR-0007 put the L1–L3 states in the in-lab S3 (versitygw on the `core` VM) with
`use_lockfile`, encrypted through OpenBao Transit. Since then ADR-0031 put the L0 state in a
dedicated AWS S3 bucket, created and tested on 2026-11-18. With that bucket in place, the
owner chose on 2026-11-18 to move the CI-applied states to AWS as well: they no longer depend
on `core` to be read, locking is already proven on AWS, and versitygw no longer has to pass a
locking test.

Three questions follow: which layers CI applies, where their states live, and where CI runs
`tofu`. `tofu plan` is not read-only in the sense that matters: it runs the pull request's
code (the providers it installs, the data sources it reads; `data "external"` runs any
program) with every credential the plan needs. VERIFIED:
https://www.runatlantis.io/docs/security, https://opentofu.org/docs/language/data-sources/.
The repository is public, the lab accepts no inbound connection, and ADR-0013 lets CI reach
only the bastion.

## Decision Drivers

* The lab's credentials and the decrypted states should not leave the lab.
* Fork pull requests get nothing; as few long-lived secrets in GitHub as possible.
* Nothing new on the school's host (ADR-0027); no public endpoint.
* One person must be able to run and repair it.

## Considered Options

Research of 2026-11-18 (sources under More Information):

* **Layers**: keep a separate L1 (OpenStack node VMs) applied by CI, or merge it into L0. CI
  applying L1 means libvirt access on `insa`, which amounts to root on the school's host.
* **States**: in-lab versitygw (ADR-0007), the L0 bucket with more prefixes, or a second bucket.
* **Where CI runs `tofu`**:
  * (a) on the GitHub-hosted runner, reaching the lab's APIs through Tailscale: the most common
    pattern, but the OpenStack and Transit credentials and the decrypted state are handed to a
    GitHub VM on every run, and the tailnet policy must open the APIs to CI;
  * (b) on the bastion: the GitHub-hosted runner only triggers it over SSH and carries the
    logs;
  * (c) a self-hosted runner on the bastion: GitHub says self-hosted runners "should almost
    never be used for public repositories" (VERIFIED:
    https://docs.github.com/en/actions/reference/security/secure-use);
  * (d) the runner runs `tofu` through a SOCKS tunnel via the bastion: same exposure as (a);
  * agents polling a SaaS (Scalr, env zero; HCP Terraform does not run OpenTofu, Spacelift's
    private workers need a paid plan), Atlantis (needs a public webhook endpoint), in-cluster
    controllers (tofu-controller, Crossplane, Cluster API: they cannot create the cluster they
    run in).
* **Encryption**: OpenBao Transit, AWS KMS, a pbkdf2 passphrase as a GitHub secret.

## Decision Outcome

Decided by the owner on 2026-11-18:

* **Layers.** L1 is merged into L0: every VM on `insa` (router, bastion, core, controller,
  computes) is applied by the owner from the laptop, never by CI. CI applies **L2** (OpenStack
  projects, networks, images, flavors, application credentials) and **L3** (K3s VMs, ports,
  server groups, floating IPs inside OpenStack).
* **States.** A **second AWS S3 bucket**, only for the CI layers, so that CI cannot even list
  the L0 keys (the S3 backend needs `s3:ListBucket` without a prefix condition, ADR-0031) and a
  policy mistake on one bucket cannot touch the other. CI's AWS access uses GitHub OIDC to AWS
  STS, without access keys.
* **Where CI runs `tofu`: on the bastion (option b).** The GitHub-hosted runner joins the
  tailnet with its tag (ADR-0013), opens SSH to a dedicated user on the bastion pinned to one
  wrapper, and carries the logs; the wrapper runs `tofu` inside the lab. Option (a) remains the
  fallback if the wrapper proves too costly.
* **Encryption** of the L2 and L3 states and plans: OpenTofu's `openbao` key provider with
  OpenBao Transit, as ADR-0007 planned: the state in AWS and the key in the lab, so neither
  alone reveals anything; with an offline backup of the keys (how: open question B13). Open
  question A7 (the key provider against OpenBao 2.7) still applies.

### Proposed design, decided at P3

These follow from the decision and from the independent review of 2026-11-18. They are
proposals, each decided when CI reaches L2 (P3), with a runbook like ADR-0031's:

* **AWS**: bucket settings like the L0 bucket (eu-west-3, versioning, Block Public Access,
  `BucketOwnerEnforced`, SSE-S3, TLS-only policy, same lifecycle rule); keys
  `l2/terraform.tfstate` and `l3/terraform.tfstate`; no workspaces (their `env:/` keys would
  fall outside narrow policies, which fails closed); a plan role that can only read, so `plan`
  runs with `-lock=false`, and an apply role that reads and writes the states and locks
  without `DeleteObjectVersion`; each role trusted for one protected GitHub environment
  through the `sub` claim (IAM refuses a missing or wildcard `sub`, VERIFIED:
  https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html). Since
  the bastion performs the STS exchange, the account ID, bucket name and role ARNs live in the
  bastion's private configuration, not in GitHub.
* **What a compromised CI step can still do.** The job holds `id-token: write`, so any step can
  mint its own token and call `AssumeRoleWithWebIdentity` from the runner itself: it gets the
  job's AWS role (ciphertext only; an overwrite is recoverable from the bucket's versions), but
  not OpenBao or the OpenStack APIs, which are reachable only through the wrapper. The job that
  holds `id-token` therefore runs only a few SHA-pinned actions and no checkout.
* **Who may plan.** Renovate (ADR-0024) and anyone with a branch can open a pull request, and a
  `pull_request` run uses the workflow file from the pull request. Fork pull requests get no
  OIDC token (INFERRED from GitHub's read-only fork token), but the plan path must still be
  bound to the owner: OpenBao JWT roles bound to `repository_id`, `environment` and the
  owner's `actor_id` (and a `sub` template including it), or the owner as required reviewer of
  the plan environment. The plan uses an OpenStack application credential with the reader
  role only.
* **The wrapper** (`sshd` `ForceCommand` in a `Match` block, `DisableForwarding yes`,
  `PermitTTY no`; never a `force-command` from an SSH certificate, which OpenBao's SSH CA can
  let a requester override):
  * verbs only: `plan <l2|l3> <sha>` and `apply <l2|l3> <sha>`; client text never reaches a
    shell;
  * `apply` only when the job's token says `ref=refs/heads/main`, event `push`, environment
    `tofu-apply`, and its commit claim equals `<sha>`, and `<sha>` is still the head of `main`;
    it applies the saved plan the owner reviewed (where plan files are kept is decided at P3).
    A GitHub signature on the commit proves nothing here (squash merges are signed by
    GitHub's own key);
  * tokens on stdin, rejected when older than 60 s or already used (`jti` recorded), with
    distinct audiences for AWS and OpenBao; OpenBao JWT roles with `bound_audiences` and a
    short `token_ttl`;
  * the commit is fetched outside the sandbox; `tofu` runs in a fresh rootless sandbox
    (bubblewrap or rootless podman) as a user that cannot read the operator's home or the
    Kolla and Ansible keys; per-user `nftables` egress only to the OpenStack APIs, OpenBao and
    the bucket's endpoint, no GitHub and no general DNS;
  * providers only from a local mirror filled by the owner from `main`, with hashes checked
    against `.terraform.lock.hcl`, containing no `external`, `http`, `local` or `null`
    provider; encryption set by the wrapper through `TF_ENCRYPTION`, which overrides the code;
  * all runs serialised with a lock shared with the Ansible and Kolla runs; only a plan
    summary goes to the public log.
* **SSH authentication of the runner** (open question B12): the runner cannot reach OpenBao, so
  the OpenBao SSH CA does not fit, and Tailscale SSH would bypass `ForceCommand` (INFERRED).
  The remaining option is a static, low-value key stored as a GitHub secret (the OIDC token is
  still required); a long-lived secret that ADR-0013 aimed to avoid.
* **Tailnet**: the CI tag may reach only the bastion's SSH port (open question B15, a change to
  the owner's tailnet policy).
* **Off-AWS copy** of the L2 and L3 states, like ADR-0031's for L0, or not, since they can be
  rebuilt by import (open question B14).
* **Between layers**, L3 looks up L2's objects by name through OpenStack data sources instead of
  `terraform_remote_state` (which would give L3 the whole L2 state and need L2's key).
* **Bastion memory**: the 768 MiB bastion (ADR-0030) must also hold the sandbox and `tofu` with
  the OpenStack provider (ESTIMATED 200–400 MiB), measured under open question A2.

### Consequences

* Good, because every OpenTofu state is off the lab, versioned and locked the same way, and
  rebuilding `core` needs no state stored on `core`.
* Good, because the lab's credentials and decrypted states stay in the lab: a compromised CI
  step reaches at most the AWS role of its job (ciphertext), not OpenBao or OpenStack.
* Good, because versitygw no longer carries state: open question A3 (its conditional writes)
  is dropped; it keeps K3s etcd snapshots and the CloudNativePG and OpenBao backups (ADR-0012).
* Bad, because every CI plan and apply now depends on AWS, and on the lab being up (OpenBao
  and the OpenStack APIs are needed anyway).
* Bad, because the bastion wrapper and sandbox are custom security code to write, test and keep
  tight, on the lab's most exposed VM, next to the Kolla and Ansible keys, and on 768 MiB.
* Bad, because states holding application-credential secrets leave the lab (encrypted).

### Confirmation

Before the first CI apply (P3): the AWS resources created and read back like ADR-0031's; tests:
a token for the plan environment is refused by the apply role; a fork pull request gets no
OIDC token; the plan role cannot write; `apply` of a commit not at the head of `main` is
refused; a replayed or old token is refused; a Renovate-authored or non-owner pull request
gets no plan; the sandbox cannot reach GitHub or another bucket; the encrypted objects are
unreadable without OpenBao.

## More Information

Research of 2026-11-18 on how teams run infrastructure CI into private networks: SaaS agents
(https://developer.hashicorp.com/terraform/cloud-docs/agents/requirements,
https://spacelift.io/pricing, https://www.envzero.com/pricing, https://scalr.com/pricing),
Atlantis (https://www.runatlantis.io/docs/deployment), GitHub's self-hosted runner warning,
Tailscale workload identity for CI (https://github.com/tailscale/github-action), `sshd`
forced commands (https://man.openbsd.org/sshd.8, https://man.openbsd.org/sshd_config), GitHub
OIDC and environments (https://docs.github.com/en/actions/reference/security/oidc,
https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
OpenTofu state encryption (https://opentofu.org/docs/language/state/encryption/),
tofu-controller (https://github.com/flux-iac/tofu-controller). Independent review of the same
day: no blocker; its findings shaped the proposed design above.
