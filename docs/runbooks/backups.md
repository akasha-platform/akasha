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
   device (the owner's phone). Undoing an attack (delete markers, overwrites) needs
   `akasha-admin`'s password and MFA too.
2. The paper sheet: the restic password of `laptop`, the bucket name and the account ID (an
   IAM user signs in with it).

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
# Only restic's lock files are ever cleaned up: their old versions go once their lock has
# expired and they have been noncurrent for 7 days. Every version of the repository's data is
# kept, even deleted or overwritten, so that the admin can always recover it (ADR-0048).
cat > "$w/lifecycle.json" <<'EOF'
{"Rules":[
 {"ID":"locks-laptop","Status":"Enabled","Filter":{"Prefix":"laptop/locks/"},
  "NoncurrentVersionExpiration":{"NoncurrentDays":7},
  "Expiration":{"ExpiredObjectDeleteMarker":true}},
 {"ID":"abort-multipart","Status":"Enabled","Filter":{},
  "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --lifecycle-configuration "file://$w/lifecycle.json" 2>&1 | mb

# The user, append-only (restic's recommended model): read and add objects, delete restic's
# lock files only, read versions and retentions (checks). It never deletes data, a version, a
# retention, the lock or the bucket's configuration; forget/prune run as akasha-admin.
cat > "$w/backup.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"Bucket","Effect":"Allow",
  "Action":["s3:ListBucket","s3:ListBucketVersions","s3:GetBucketLocation"],
  "Resource":"arn:aws:s3:::$BACKUP_BUCKET"},
 {"Sid":"Objects","Effect":"Allow",
  "Action":["s3:GetObject","s3:PutObject","s3:GetObjectRetention"],
  "Resource":"arn:aws:s3:::$BACKUP_BUCKET/*"},
 {"Sid":"LocksOnly","Effect":"Allow","Action":"s3:DeleteObject",
  "Resource":"arn:aws:s3:::$BACKUP_BUCKET/*/locks/*"},
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
aws s3api get-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" --query 'Rules[].ID' 2>&1 | mb
rm -rf "$w"; aws logout --profile akasha-admin; unset AWS_PROFILE
```

Nothing is locked yet: an empty bucket can still be deleted. **The point of no return is the
first upload** (`restic init`): from then on, every object stays at least 90 days.

## Once: the restic password and the repository

```bash
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-restic --init laptop
# write it on paper, with the bucket name and the account ID (IAM users sign in with it):
#   grep BACKUP_BUCKET ~/akasha-private/aws-backup.env; grep ACCOUNT ~/akasha-private/aws-l0-state.env
# then: clear; printf '\e[3J'
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --service akasha-restic --verify laptop
```

## Every session (as `akasha-backup`)

```bash
cd ~/Documents/dev/Projets/akasha && eval "$(mise activate bash)" && set -o pipefail
aws login --profile akasha-backup --region eu-west-3            # browser: akasha-backup + MFA
. ~/akasha-private/aws-l0-state.env; . ~/akasha-private/aws-backup.env
mb() { sed "s/$ACCOUNT/<account>/g; s/$BACKUP_BUCKET/<backup-bucket>/g; s/$BUCKET/<bucket>/g"; }
# Temporary credentials of the session, for restic (never printed). `aws login` renews them
# about every 15 minutes and restic does not: run `creds` again before each block.
creds() { eval "$(aws configure export-credentials --profile akasha-backup --region eu-west-3 --format env)"; }
export AWS_DEFAULT_REGION=eu-west-3
export RESTIC_REPOSITORY="s3:https://s3.eu-west-3.amazonaws.com/$BACKUP_BUCKET/laptop"
# restic runs this without a shell, from the current directory: absolute paths.
export RESTIC_PASSWORD_COMMAND="mise exec -C $PWD -- uv run --project $PWD --locked --quiet python $PWD/infra/opentofu/scripts/tofu_passphrase.py --service akasha-restic --plain laptop"
creds && restic init 2>&1 | mb                                   # once: "created restic repository"
```

## Back up (after every change in `~/akasha-private`)

```bash
creds && restic backup --host akasha-laptop ~/akasha-private 2>&1 | mb
creds && restic check 2>&1 | mb                                  # "no errors were found"
creds && restic snapshots 2>&1 | mb
```

A run interrupted by an expired session leaves a stale lock: `creds && restic unlock`.

End of session:
`aws logout --profile akasha-backup; unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN RESTIC_PASSWORD_COMMAND RESTIC_REPOSITORY`.

## Restore

```bash
t=$(umask 077; mktemp -d)
creds && restic restore latest --host akasha-laptop --target "$t" 2>&1 | mb
diff -r ~/akasha-private "$t$HOME/akasha-private" && echo "identical"     # a test restore
rm -rf "$t"
```

On a new machine:
1. Install the pinned toolchain (`mise install` in a checkout).
2. `aws login --profile akasha-backup` with the account ID from paper, the password and MFA.
3. The session block above, with `BACKUP_BUCKET` and `ACCOUNT` typed from paper, and
   `RESTIC_PASSWORD_COMMAND` **unset**: restic asks for the password. Type it from paper
   **without the spaces** between the groups (restic does not remove them).
4. Restore, then `tofu_passphrase.py --service akasha-restic --restore laptop`.

## Check the lock (once, then from time to time)

On a canary object of its own, never on the repository's files (a wrong lock would let the
admin's delete succeed). The canary stays 90 days, a few bytes.

```bash
k=lock-canary-$(date -u +%Y%m%d)
creds && printf 'canary\n' | aws s3 cp --only-show-errors - "s3://$BACKUP_BUCKET/$k" 2>&1 | mb
v=$(aws s3api list-object-versions --bucket "$BACKUP_BUCKET" --prefix "$k" --query 'Versions[0].VersionId' --output text 2>&1)
aws s3api get-object-retention --bucket "$BACKUP_BUCKET" --key "$k" --version-id "$v" 2>&1 | mb   # COMPLIANCE, +90 days
aws s3api delete-object --bucket "$BACKUP_BUCKET" --key "$k" --version-id "$v" 2>&1 | mb          # AccessDenied (policy)
aws s3api delete-object --bucket "$BACKUP_BUCKET" --key laptop/config 2>&1 | mb                   # AccessDenied (append-only)
# Only if get-object-retention showed COMPLIANCE: the admin is refused too.
aws login --profile akasha-admin --region eu-west-3
(unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
 aws s3api delete-object --profile akasha-admin --bucket "$BACKUP_BUCKET" --key "$k" --version-id "$v" 2>&1 | mb)  # AccessDenied (Object Lock)
aws logout --profile akasha-admin
```

## Retention

Keep every snapshot for now (a few hundred KB each). `akasha-backup` cannot run `forget` or
`prune` (append-only). When it is ever needed, run them as `akasha-admin` (export its
credentials the same way), with `--keep-within` rather than `--keep-last`: an attacker
holding `akasha-backup` could add garbage snapshots (restic docs, "Security considerations in
append-only mode"). Old versions are kept anyway: the lifecycle only cleans `laptop/locks/`.

## Undo an attack (as `akasha-admin`)

`akasha-backup` can neither delete data nor delete a version, but it can overwrite an object
(the old version stays). To put back the data as it was before a date, copy the older
versions over the current ones (one key at a time):

```bash
aws s3api list-object-versions --bucket "$BACKUP_BUCKET" --prefix laptop/ \
  --query 'Versions[?LastModified<`2026-12-01`].[Key,VersionId,LastModified]' --output text | mb
aws s3api copy-object --bucket "$BACKUP_BUCKET" --key <key> \
  --copy-source "$BACKUP_BUCKET/<key>?versionId=<version>" 2>&1 | mb
```

Then `restic check --read-data`. Rehearsed: not yet (ADR-0048).

## Failure modes

* **`ExpiredToken` or `AccessDenied` from restic**: run `creds` again; if the 12-hour session
  is over, `aws login` first. restic reads only the environment's credentials.
* **An unexpected upload** (a wrong path, an attacker): it stays 90 days and is billed. The
  account's 1 USD budget alert (runbook `aws-l0-state.md`) is the warning; IAM cannot cap
  the size.
* **Repository password lost** (keyring and paper): the backups cannot be read. Make a new
  repository and back up again.
* **A version must be deleted** before 90 days: impossible in compliance mode, even for root.
  restic encrypts everything, so nothing in the bucket is readable without the password.
