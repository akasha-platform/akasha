---
status: accepted
date: 2026-11-18
decision-makers: dhuy21
---

# L0 OpenTofu state in a dedicated AWS S3 bucket

## Context and Problem Statement

ADR-0007 gives every OpenTofu layer its own state: L1–L3 in the in-lab S3 (versitygw on the
`core` VM) with `use_lockfile`, and the L0 state encrypted with a `pbkdf2` passphrase. The L0
stack creates every lab VM on `insa`, `core` included, so its state cannot live in the S3 that
`core` serves: a broken `core` would take with it the only state able to repair it (open
question B3).

Facts from the owner (2026-11-17): only the owner applies L0, never CI (CI handles L1 and
above through the bastion that L0 creates); the owner works from **several laptops**, so the
state must be shared and locked; the owner already has an AWS account (also chosen for the
off-site restic backups, ADR-0012).

The state is sensitive: provider `dmacvicar/libvirt` 0.9.9 stores cloud-init `user_data` in
it unencrypted (VERIFIED: `internal/provider/cloudinit_disk_resource.go` at v0.9.9). The
repository is public: no state, bucket name or account ID is committed.

## Decision Drivers

* Locking across several machines.
* Survives the loss of `insa` (lent by the school) and of one laptop.
* Recoverable: earlier versions of the state can be restored.
* Nothing new on `insa` (ADR-0027), nothing secret in the repository.
* Low effort and cost for a single operator.

## Considered Options

Research and an independent review on 2026-11-17:

* **Dedicated AWS S3 bucket**: the S3 backend locks natively with `use_lockfile` (conditional
  writes, no DynamoDB; VERIFIED: OpenTofu v1.13.9 `client.go`, AWS
  https://aws.amazon.com/about-aws/whats-new/2024/08/amazon-s3-conditional-writes/); OpenTofu
  "highly recommends" versioning; AWS Prescriptive Guidance recommends `use_lockfile` plus
  versioning for state (VERIFIED:
  https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html).
* **GitLab-managed state** (`http` backend, free tier with locking and versions): sound, but a
  second platform and account.
* **Encrypted local file + copies**: no lock between machines; manual syncing risks applying on
  a stale state.
* **File on `insa`**: no lock over SSH; lost together with the VMs; on a lent machine.
* **Encrypted state in a private Git repository**: no locking; HashiCorp and Gruntwork advise
  against state in Git.
* **Local first, then migrate into the in-lab S3**: circular (above).

## Decision Outcome

Chosen option: **"Dedicated AWS S3 bucket"**, chosen by the owner on 2026-11-17, with these
details (also chosen by the owner: region, identity, manual creation):

* **Bucket** in `eu-west-3` (Paris), used only for OpenTofu state, separate from the restic
  bucket. Versioning on; Block Public Access; a bucket policy that refuses non-TLS requests;
  default encryption SSE-S3; lifecycle: a noncurrent version is removed only when it is older
  than 180 days and not among the 100 newest; expired delete markers removed (lock files create
  many versions). Created **by hand from a CLI
  runbook** that the owner runs once; its output is checked before use.
* **Backend**: `s3` with `use_lockfile = true`, key `l0/terraform.tfstate`. The bucket name,
  region and account ID live in a partial backend configuration file outside the repository
  (`~/akasha-private/`), passed with `-backend-config=`; the repository keeps placeholders.
* **Client-side encryption** stays as in ADR-0007: key provider `pbkdf2` (≥ 16-character
  passphrase), method `aes_gcm`, `enforced = true` for state and plan files. Reading the state
  needs both AWS access and the passphrase; the encrypted envelope keeps only the pbkdf2
  parameters in clear (VERIFIED: `internal/encryption/base.go`). `aws_kms` was not chosen: it
  ties the key to the same account, costs about 1 USD/month (ESTIMATED) and is unusable
  offline. The passphrase is kept in a password manager and fed through a key-provider command
  rather than an environment variable; an offline copy exists. It is **not** a GitHub Actions
  secret, since CI never applies L0 (this corrects `docs/research/07-trust-and-data.md`).
* **Identity**: a dedicated IAM user with MFA and console sign-in, holding only the L0 state
  policy; each laptop uses `aws login` (short-lived credentials, at most 12 hours; supported by
  OpenTofu since 1.12, VERIFIED: OpenTofu `s3.mdx`). No long-lived access keys. IAM Identity
  Center was not chosen: on a standalone account it needs an AWS Organization.
* **Policy of that user** (VERIFIED against OpenTofu v1.13.9 `backend/remote-state/s3`):
  `s3:ListBucket` on the bucket (without a prefix condition: the first `init` reads a missing
  key), `s3:GetObject` and `s3:PutObject` on the state key, `s3:GetObject`, `s3:PutObject`
  and `s3:DeleteObject` on `<key>.tflock`. No `DeleteObjectVersion`, so it cannot erase
  history; restoring an old version is done with the administrator IAM user `akasha-admin`
  (MFA), created so that the root user is no longer used (owner's choice of 2026-11-18).
* **Off-AWS copy**: after every L0 apply, the raw encrypted state object is copied to a medium
  outside AWS (applies are rare), so losing the AWS account does not lose the state. The
  account itself gets root MFA, alternate contacts and a billing alarm.
* **Tools**: OpenTofu is bumped to **1.13.9** before the first apply: it fixes a local-backend
  bug where an interrupted first apply keeps only the last resource in state (VERIFIED:
  https://github.com/opentofu/opentofu/pull/4811). The AWS CLI (≥ 2.32 for `aws login`) is
  pinned through mise (ADR-0022), not installed globally.

### Consequences

* Good, because two laptops cannot apply at the same time, and every earlier state can be
  restored.
* Good, because the L0 state survives the loss of `insa` or of a laptop, and nothing is added
  to the school's host or to the public repository.
* Bad, because the lab depends on an AWS account for its bootstrap layer (mitigated by the
  off-AWS copy) and the same account will hold the restic backups.
* Bad, because the operator handles an AWS sign-in and a passphrase on each laptop.

### Confirmation

Before the first L0 apply (step 6): the runbook's output checked; `tofu init` against an empty
key works with the narrow policy; two laptops planning at once get one lock error; the
encrypted object in S3 is not readable without the passphrase.

### Implementation (2026-11-18)

Done by the owner from [the runbook](../runbooks/aws-l0-state.md), reviewed independently
beforehand (no blocker; six should-fix items applied):

* Root used once in the console: root MFA and no root access key checked, alternate contacts,
  a 1 USD monthly budget alert, and the administrator user `akasha-admin` created with MFA
  assigned before console access; root then signed out.
* As `akasha-admin`: the bucket was created and read back: versioning enabled, the four Block
  Public Access settings true, `BucketOwnerEnforced`, SSE-S3 (AWS also blocks SSE-C by
  default), the TLS-only policy, the lifecycle rule (180 days, 100 newest versions kept,
  expired delete markers removed, incomplete uploads aborted after 7 days). `akasha-l0` has
  exactly the two policies, one MFA device, no access key, and no forced password reset.
  `aws logout` removed the cached session; it reports that access tokens already issued stay
  valid for at most 15 minutes.
* As `akasha-l0` (`aws login`), before any state exists: deleting an object version is
  denied, the lock object can be written and released, an empty state key reads as
  not found (so `tofu init` works with the narrow policy), and any other key is denied. The
  private partial backend configuration exists (mode 600).

Still to confirm in step 6 (open question A23): `tofu init` and a plan with the encrypted
state, a lock conflict between two laptops, and the encrypted object being unreadable without
the passphrase.

## More Information

Findings of the independent review that concern the libvirt provider, whatever the backend,
and are carried into the step-6 design (open question A23):

* The cloud-init ISO is written to the temporary directory of the machine running OpenTofu;
  when the file is missing (another laptop, a reboot clearing `/tmp`), the provider removes
  the resource from state, and the volume built from it is planned for replacement, which can
  stop the VM (VERIFIED: `cloudinit_disk_resource.go:170, 233-240`, `volume_resource.go`
  `RequiresReplace` on `create`). Mitigations: `lifecycle { ignore_changes = [create] }` on
  every volume built from content, and no secret in cloud-init user data (hostname, network,
  public SSH key only; secrets come later through Ansible).
* After a lost state, `import` of volumes leaves `create` empty and plans replacements
  (VERIFIED: `volume_resource.go` `ImportState`); the same `ignore_changes` applies, and a
  recovery drill must end with a plan that destroys nothing.

## Updates

* 2026-11-18: the owner now works from **one laptop** only. The decision stands: the lock still
  protects against two terminals applying at once, the bucket and its versions survive the
  loss of that laptop, and a second machine can be added later with `aws login` and a copy of
  the private files.
* 2026-11-18: L1 is merged into L0 ([ADR-0032](0032-ci-states-in-aws-s3.md)); CI applies only
  L2 and L3, whose states live in a second bucket.
