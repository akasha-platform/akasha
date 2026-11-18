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
owner chose on 2026-11-18 to move the CI-applied states to AWS as well: they then no longer
depend on `core` to be read (rebuilding `core` needs no state stored on `core`), locking is
already proven on AWS, and versitygw no longer has to pass a locking test.

Three questions follow: which layers CI applies, where the states live, and where CI runs
`tofu`. `tofu plan` is not read-only in the sense that matters: it runs the pull request's
code (providers it installs, data sources it reads, `data "external"` runs any program) with
every credential the plan needs. VERIFIED: https://www.runatlantis.io/docs/security,
https://opentofu.org/docs/language/data-sources/. The repository is public, the lab accepts
no inbound connection, and ADR-0013 lets CI reach only the bastion.

## Decision Drivers

* The lab's credentials and the decrypted states should not leave the lab.
* No long-lived secret in GitHub; fork pull requests get nothing.
* Nothing new on the school's host (ADR-0027); no public endpoint.
* One person must be able to run and repair it.

## Considered Options

Research of 2026-11-18 (sources in the notes):

* **Layers**: keep a separate L1 (OpenStack node VMs) for CI, or merge it into L0. CI applying
  L1 means libvirt access on `insa`, which amounts to root on the school's host.
* **States**: in-lab versitygw (ADR-0007), the L0 bucket with more prefixes, or a second
  bucket.
* **Where CI runs `tofu`**:
  * (a) on the GitHub-hosted runner, reaching the lab APIs through Tailscale: the most common
    pattern, but the OpenStack and Transit credentials and the decrypted state are handed to a
    GitHub VM on every run, and the tailnet policy must open the APIs to CI;
  * (b) on the bastion: the GitHub-hosted runner only triggers it over SSH and carries the
    logs;
  * (c) a self-hosted runner on the bastion: GitHub says self-hosted runners "should almost
    never be used for public repositories" (VERIFIED:
    https://docs.github.com/en/actions/reference/security/secure-use);
  * (d) the runner runs `tofu` through a SOCKS tunnel via the bastion: same exposure as (a);
  * agents polling a SaaS (Scalr, env zero; HCP Terraform does not run OpenTofu, Spacelift
    private workers need a paid plan), Atlantis (needs a public webhook endpoint), in-cluster
    controllers (tofu-controller, Crossplane, Cluster API: cannot create the cluster they run
    in).
* **Encryption**: OpenBao Transit, AWS KMS, a pbkdf2 passphrase as a GitHub secret.

## Decision Outcome

Chosen by the owner on 2026-11-18:

* **Layers.** L1 is merged into L0: every VM on `insa` (router, bastion, core, controller,
  computes) is applied by the owner from the laptop, never by CI. CI applies **L2**
  (OpenStack projects, networks, images, flavors, application credentials) and **L3** (K3s
  VMs, ports, server groups, floating IPs inside OpenStack).
* **States.** A **second AWS S3 bucket**, only for the CI layers, configured like the L0
  bucket (eu-west-3, versioning, Block Public Access, `BucketOwnerEnforced`, SSE-S3, TLS-only
  policy, same lifecycle rule), with keys `l2/terraform.tfstate` and `l3/terraform.tfstate`
  and `use_lockfile`. A separate bucket keeps CI from even listing the L0 keys (the S3
  backend needs `s3:ListBucket` without a prefix condition, ADR-0031), and a policy mistake on
  one bucket cannot touch the other. No workspaces (their `env:/` keys would fall outside the
  narrow policies, which fails closed).
* **CI's AWS access.** GitHub OIDC to AWS STS, no access key in GitHub: an IAM OIDC identity
  provider for `token.actions.githubusercontent.com`; a **plan** role (read the two states)
  and an **apply** role (read and write them and their locks, no `DeleteObjectVersion`), each
  trusted only for one protected GitHub environment through the `sub` claim. IAM refuses a
  GitHub trust policy whose `sub` condition is missing or only a wildcard (VERIFIED:
  https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html). Two
  environments: `tofu-plan` (pull requests from branches of this repository) and
  `tofu-apply` (branch `main` only, the owner as required reviewer). The account ID, bucket
  name and role ARNs are environment **secrets** (masked in the public logs), and the AWS
  action runs with `mask-aws-account-id`.
* **Where CI runs `tofu`: on the bastion (option b).** The GitHub-hosted runner joins the
  tailnet with its tag (ADR-0013) and opens SSH to a dedicated user on the bastion, pinned to
  one wrapper by `sshd` (`ForceCommand` with forwarding disabled; the command is never taken
  from an SSH certificate, since OpenBao's SSH CA can let a requester override
  `force-command`). The wrapper:
  * accepts only `plan <l2|l3> <commit>` and `apply <l2|l3>`, never passing client text to a
    shell; `plan` only for a commit at the head of a branch of this repository, `apply` only
    for the signed head of `main`;
  * fetches that commit itself and runs `tofu` in a fresh, disposable directory or container
    as an unprivileged user, with providers only from a local mirror (no direct download)
    and egress limited to the OpenStack APIs, OpenBao, the S3 endpoint and GitHub;
  * receives the job's short-lived GitHub OIDC tokens on stdin and exchanges them itself for
    the AWS role and for OpenBao (JWT auth bound to the repository, the environment and the
    ref); the SSH key alone does nothing;
  * returns only a plan summary to the public log.
  The lab's credentials and decrypted states stay in the lab; a compromised action in the job
  can only call the wrapper's verbs. Option (a) remains the fallback if the wrapper proves too
  costly.
* **Encryption** of the L2 and L3 states and plans: OpenTofu's `openbao` key provider with one
  Transit key per layer (`enforced = true`), as ADR-0007 planned; the state in AWS and the key
  in the lab, so neither alone reveals anything. An offline backup of the Transit keys is
  kept, since the states cannot be read while OpenBao is down. Open question A7 (the key
  provider against OpenBao 2.7) still applies.
* **Between layers**, L3 looks up L2's objects by name through OpenStack data sources instead
  of `terraform_remote_state` (which would give L3 the whole L2 state and need L2's key).

### Consequences

* Good, because every OpenTofu state is off the lab, versioned and locked the same way, and
  rebuilding `core` needs no state stored on `core`.
* Good, because fork pull requests get no token, and a compromised job cannot take the lab's
  credentials out of it.
* Good, because versitygw no longer carries state: open question A3 (its conditional writes)
  is dropped; it keeps K3s etcd snapshots and the CloudNativePG and OpenBao backups (ADR-0012).
* Bad, because every CI plan and apply now depends on AWS, and on the lab being up (OpenBao
  and the OpenStack APIs are needed anyway).
* Bad, because the bastion wrapper is custom code to write, test and keep tight, and it runs
  on a 768 MiB VM (ADR-0030): `tofu` with the OpenStack provider is ESTIMATED at 200–400 MiB,
  to be measured (open question A2).
* Bad, because states holding application-credential secrets leave the lab (encrypted).

### Confirmation

Before the first CI apply (P3): the AWS resources created and read back like ADR-0031's;
tests: a token for the pull-request environment is refused by the apply role; a fork pull
request gets no OIDC token; the plan role cannot write; `apply` of a commit not on `main` is
refused by the wrapper; the encrypted objects are unreadable without OpenBao.

## More Information

Research of 2026-11-18 on how teams run infrastructure CI into private networks: SaaS agents
(https://developer.hashicorp.com/terraform/cloud-docs/agents/requirements,
https://spacelift.io/pricing, https://www.envzero.com/pricing, https://scalr.com/pricing),
Atlantis (https://www.runatlantis.io/docs/deployment), GitHub's self-hosted runner warning,
Tailscale workload identity for CI (https://github.com/tailscale/github-action), `sshd`
forced commands (https://man.openbsd.org/sshd.8), tofu-controller
(https://github.com/flux-iac/tofu-controller). Details of the wrapper, the SSH
authentication and the AWS runbook are decided when CI reaches L2 (P3).
