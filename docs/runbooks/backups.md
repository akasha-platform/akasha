# Off-site backups: restic to AWS S3 with Object Lock

Design: [ADR-0048](../adr/0048-off-site-backups-restic-s3-object-lock.md). One AWS bucket in
`eu-west-3`, Object Lock in **compliance** mode with a 90-day default retention. One restic
repository per source, each with its own password:

| Repository | Source | Password (keyring service `akasha-restic`) | Step |
|---|---|---|---|
| `laptop` | `~/akasha-private` | `laptop` | 7e-1 |
| `core` | OpenBao's Raft snapshots | (7e-2) | 7e-2 |

The bucket name is private: `~/akasha-private/aws-backup.env`, and on the same sheet of paper
as the repository password. Commands run on the laptop, from the repository, in bash. Every
output meant to be pasted goes through `mb`, which masks the account ID and the bucket names.

## Recovery needs (keep them off the laptop)

1. The console password of `akasha-backup` (in the owner's head or on paper) and its MFA
   device (the owner's phone).
2. The paper sheet: the restic password of `laptop` and the bucket name.

With those, any machine with restic restores `~/akasha-private` (section "Restore").

## Once: bucket and IAM user (as `akasha-admin`)

```bash
aws login --profile akasha-admin --region eu-west-3          # browser: akasha-admin + MFA
export AWS_PROFILE=akasha-admin AWS_REGION=eu-west-3; . ~/akasha-private/aws-l0-state.env
f=~/akasha-private/aws-backup.env
[ -s "$f" ] || (umask 077; printf 'BACKUP_BUCKET=%s\n' "akasha-backup-$(openssl rand -hex 4)" > "$f")
. "$f"; mb() { sed "s/$ACCOUNT/<account>/g; s/$BACKUP_BUCKET/<backup-bucket>/g; s/$BUCKET/<bucket>/g"; }
aws sts get-caller-identity --query Arn --output text 2>&1 | mb      # …:user/akasha-admin
w=$(umask 077; mktemp -d)

# The bucket, with Object Lock (which also turns versioning on). Compliance mode cannot be
# shortened or removed: no one, root included, deletes a locked version before 90 days.
aws s3api create-bucket --bucket "$BACKUP_BUCKET" --object-lock-enabled-for-bucket \
  --create-bucket-configuration LocationConstraint=eu-west-3 --query Location --output text 2>&1 | mb
aws s3api put-public-access-block --bucket "$BACKUP_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true 2>&1 | mb
aws s3api put-bucket-ownership-controls --bucket "$BACKUP_BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' 2>&1 | mb
aws s3api put-bucket-encryption --bucket "$BACKUP_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' 2>&1 | mb
aws s3api put-object-lock-configuration --bucket "$BACKUP_BUCKET" --object-lock-configuration \
  '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":90}}}' 2>&1 | mb
cat > "$w/tls-only.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny",
 "Principal":"*","Action":"s3:*",
 "Resource":["arn:aws:s3:::$BACKUP_BUCKET","arn:aws:s3:::$BACKUP_BUCKET/*"],
 "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
EOF
aws s3api put-bucket-policy --bucket "$BACKUP_BUCKET" --policy "file://$w/tls-only.json" 2>&1 | mb
# Deleted or replaced versions (restic's prune, its lock files) go once their lock has expired
# and they have been noncurrent for 7 days; a locked version is never deleted by lifecycle.
cat > "$w/lifecycle.json" <<'EOF'
{"Rules":[{"ID":"expire-noncurrent","Status":"Enabled","Filter":{},
 "NoncurrentVersionExpiration":{"NoncurrentDays":7},
 "Expiration":{"ExpiredObjectDeleteMarker":true},
 "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --lifecycle-configuration "file://$w/lifecycle.json" 2>&1 | mb

# The user: read and add objects, place delete markers (restic removes its lock files), read
# versions and retentions (checks); never delete a version or change a retention, the lock or
# the bucket's configuration.
cat > "$w/backup.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"Bucket","Effect":"Allow",
  "Action":["s3:ListBucket","s3:ListBucketVersions","s3:GetBucketLocation"],
  "Resource":"arn:aws:s3:::$BACKUP_BUCKET"},
 {"Sid":"Objects","Effect":"Allow",
  "Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:GetObjectRetention"],
  "Resource":"arn:aws:s3:::$BACKUP_BUCKET/*"},
 {"Sid":"NeverDestroyHistory","Effect":"Deny",
  "Action":["s3:DeleteObjectVersion","s3:PutObjectRetention","s3:PutObjectLegalHold",
            "s3:BypassGovernanceRetention","s3:PutBucketObjectLockConfiguration",
            "s3:PutLifecycleConfiguration","s3:PutBucketPolicy","s3:DeleteBucketPolicy",
            "s3:PutBucketVersioning","s3:DeleteBucket"],
  "Resource":["arn:aws:s3:::$BACKUP_BUCKET","arn:aws:s3:::$BACKUP_BUCKET/*"]}]}
EOF
aws iam create-policy --policy-name akasha-backup-repo --policy-document "file://$w/backup.json" \
  --query Policy.Arn --output text 2>&1 | mb
aws iam create-user --user-name akasha-backup --query User.Arn --output text 2>&1 | mb
aws iam attach-user-policy --user-name akasha-backup \
  --policy-arn "arn:aws:iam::$ACCOUNT:policy/akasha-backup-repo" 2>&1 | mb
aws iam attach-user-policy --user-name akasha-backup \
  --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess 2>&1 | mb
```

Console, as `akasha-admin`: `akasha-backup` → Security credentials → **Assign MFA device** (the
phone), then **Enable console access** with a custom password kept off the laptop, no reset.

Checks, still as `akasha-admin`:

```bash
aws s3api get-bucket-versioning --bucket "$BACKUP_BUCKET" 2>&1 | mb                # Enabled
aws s3api get-object-lock-configuration --bucket "$BACKUP_BUCKET" 2>&1 | mb        # COMPLIANCE, 90
aws iam list-attached-user-policies --user-name akasha-backup --query 'AttachedPolicies[].PolicyName' 2>&1 | mb
```

## Once: the restic password and the repository

```bash
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-restic --init laptop
# write it on paper, with the bucket name (grep BACKUP_BUCKET ~/akasha-private/aws-backup.env),
# then: clear; printf '\e[3J'
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-restic --verify laptop
```

## Every session (as `akasha-backup`)

```bash
cd ~/Documents/dev/Projets/akasha && eval "$(mise activate bash)" && set -o pipefail
aws login --profile akasha-backup --region eu-west-3            # browser: akasha-backup + MFA
. ~/akasha-private/aws-l0-state.env; . ~/akasha-private/aws-backup.env
mb() { sed "s/$ACCOUNT/<account>/g; s/$BACKUP_BUCKET/<backup-bucket>/g; s/$BUCKET/<bucket>/g"; }
# Temporary credentials of the session, for restic (never printed).
eval "$(aws configure export-credentials --profile akasha-backup --region eu-west-3 --format env)"
export AWS_DEFAULT_REGION=eu-west-3
export RESTIC_REPOSITORY="s3:https://s3.eu-west-3.amazonaws.com/$BACKUP_BUCKET/laptop"
export RESTIC_PASSWORD_COMMAND="mise exec -- uv run --locked --quiet python infra/opentofu/scripts/tofu_passphrase.py --service akasha-restic --plain laptop"
restic init 2>&1 | mb                                            # once: "created restic repository"
```

## Back up (after every change in `~/akasha-private`)

```bash
restic backup --host akasha-laptop ~/akasha-private 2>&1 | mb
restic check 2>&1 | mb                                           # "no errors were found"
restic snapshots 2>&1 | mb
```

## Restore

```bash
t=$(umask 077; mktemp -d)
restic restore latest --host akasha-laptop --target "$t" 2>&1 | mb
diff -r ~/akasha-private "$t$HOME/akasha-private" && echo "identical"     # a test restore
rm -rf "$t"
```

On a new machine: install restic (mise), `aws login --profile akasha-backup` (password and
MFA), set `RESTIC_REPOSITORY` with the bucket from paper, leave `RESTIC_PASSWORD_COMMAND` unset
(restic asks for the password: type it from paper), restore, then `--restore` the passwords
into the keyring.

## Check the lock (once, then from time to time)

```bash
k=laptop/config
v=$(aws s3api list-object-versions --profile akasha-backup --bucket "$BACKUP_BUCKET" --prefix "$k" \
  --query 'Versions[0].VersionId' --output text 2>&1)
aws s3api get-object-retention --profile akasha-backup --bucket "$BACKUP_BUCKET" --key "$k" \
  --version-id "$v" 2>&1 | mb                                     # COMPLIANCE, RetainUntilDate +90 days
aws s3api delete-object --profile akasha-backup --bucket "$BACKUP_BUCKET" --key "$k" \
  --version-id "$v" 2>&1 | mb                                     # AccessDenied (the user's policy)
aws s3api delete-object --profile akasha-admin --bucket "$BACKUP_BUCKET" --key "$k" \
  --version-id "$v" 2>&1 | mb                                     # AccessDenied (Object Lock, even admin)
```

## Retention

Keep every snapshot for now (a few hundred KB each). When needed:
`restic forget --host akasha-laptop --keep-last 30 --prune`. It only places delete markers:
the versions stay locked for 90 days from their upload, then the lifecycle removes them 7 days
after they became noncurrent.

## Failure modes

* **`AccessDenied` from restic**: the session expired (`aws login` again, then `eval` the
  credentials again), or `AWS_PROFILE` points to another user.
* **Repository password lost** (keyring and paper): the backups cannot be read. Make a new
  repository and back up again.
* **A version must be deleted** before 90 days: impossible in compliance mode, even for root.
  restic encrypts everything, so nothing in the bucket is readable without the password.
