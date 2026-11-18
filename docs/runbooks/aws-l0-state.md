# AWS bucket and IAM users for the L0 OpenTofu state

Design: [ADR-0031](../adr/0031-l0-state-in-aws-s3.md). Creates, once, in the owner's AWS
account (paid plan):

* `akasha-admin`: an administrator IAM user with MFA, so that the root user is no longer used
  (root stays for the tasks that require it);
* a versioned S3 bucket for the L0 state in `eu-west-3`;
* `akasha-l0`: an IAM user with MFA that may only read and write the L0 state and its lock.

Run the shell steps in **bash**, on a laptop, with the pinned AWS CLI (`mise exec -- aws …` or a
mise-activated shell). Nothing here touches `insa`.

The bucket name and the account ID never go into the repository, a commit or a pasted output:
they live in `~/akasha-private/aws-l0-state.env`, and every output meant to be pasted goes
through `m` (step 2), which masks them.

## 1. Console, as root, once

1. Check: MFA is on for root; IAM → Security recommendations shows no root access key.
2. Account → Alternate contacts: add the security and billing contacts.
3. Billing and Cost Management → Budgets → Create budget → monthly cost budget of 1 USD,
   e-mail alert at 80% of actual cost.
4. IAM → Users → Create user `akasha-admin`, **without** console access for now; attach
   `AdministratorAccess`.
5. `akasha-admin` → Security credentials → **Assign MFA device**.
6. Then, and only then, `akasha-admin` → Security credentials → **Enable console access** →
   custom password from the password manager, no reset required. (MFA first: otherwise the
   password alone would let the user sign in.)
7. Sign root out of the console.

## 2. Shell, as `akasha-admin`: sign in and set the private variables

```bash
aws login --profile akasha-admin --region eu-west-3          # browser: akasha-admin + MFA
export AWS_PROFILE=akasha-admin AWS_REGION=eu-west-3

mkdir -p -m 700 ~/akasha-private; f=~/akasha-private/aws-l0-state.env
if [ -s "$f" ]; then . "$f"; else
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  if [ -n "$ACCOUNT" ]; then
    BUCKET=akasha-tfstate-$(openssl rand -hex 4)             # globally unique name
    (umask 077; printf 'BUCKET=%s\nACCOUNT=%s\nKEY=%s\n' \
      "$BUCKET" "$ACCOUNT" "l0/terraform.tfstate" > "$f")
    . "$f"
  else
    echo "STOP: not signed in as akasha-admin"
  fi
fi
m() { sed "s/$ACCOUNT/<account>/g; s/$BUCKET/<bucket>/g"; }   # mask before pasting
w=$(umask 077; mktemp -d)

aws sts get-caller-identity --query Arn --output text | m    # …:user/akasha-admin
aws iam get-account-summary --query 'SummaryMap.[AccountMFAEnabled,AccountAccessKeysPresent]'  # [1, 0]
```

## 3. Bucket

```bash
aws s3api create-bucket --bucket "$BUCKET" \
  --create-bucket-configuration LocationConstraint=eu-west-3 | m
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

cat > "$w/tls-only.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny",
 "Principal":"*","Action":"s3:*",
 "Resource":["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"],
 "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$w/tls-only.json"

# An old version is removed only when it is older than 180 days AND not among the 100 newest.
cat > "$w/lifecycle.json" <<'EOF'
{"Rules":[{"ID":"state-history","Status":"Enabled","Filter":{},
 "NoncurrentVersionExpiration":{"NoncurrentDays":180,"NewerNoncurrentVersions":100},
 "Expiration":{"ExpiredObjectDeleteMarker":true},
 "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "file://$w/lifecycle.json"
```

## 4. IAM user `akasha-l0` (no password, no access key from the shell)

```bash
cat > "$w/l0-state.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"ListBucket","Effect":"Allow","Action":"s3:ListBucket",
  "Resource":"arn:aws:s3:::$BUCKET"},
 {"Sid":"State","Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],
  "Resource":"arn:aws:s3:::$BUCKET/$KEY"},
 {"Sid":"Lock","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],
  "Resource":"arn:aws:s3:::$BUCKET/$KEY.tflock"}]}
EOF
aws iam create-policy --policy-name akasha-l0-state \
  --policy-document "file://$w/l0-state.json" --query Policy.Arn --output text | m
aws iam create-user --user-name akasha-l0 --query User.Arn --output text | m
aws iam attach-user-policy --user-name akasha-l0 \
  --policy-arn "arn:aws:iam::$ACCOUNT:policy/akasha-l0-state"
aws iam attach-user-policy --user-name akasha-l0 \
  --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess
```

Console, as `akasha-admin`: `akasha-l0` → Security credentials → **Assign MFA device**, then
**Enable console access** with a custom password from the password manager, no reset (same
order as in step 1).

## 5. Read back, then sign the administrator out

```bash
aws s3api get-bucket-versioning --bucket "$BUCKET"
aws s3api get-public-access-block --bucket "$BUCKET"
for c in ownership-controls encryption policy lifecycle-configuration; do
  aws s3api "get-bucket-$c" --bucket "$BUCKET" | m; done
aws iam list-attached-user-policies --user-name akasha-l0 | m
aws iam list-mfa-devices --user-name akasha-l0 --query 'MFADevices[].EnableDate'   # one device
aws iam list-access-keys --user-name akasha-l0 --query 'AccessKeyMetadata'         # []
rm -rf "$w"
aws logout --profile akasha-admin; unset AWS_PROFILE
ls ~/.aws/login/cache 2>/dev/null                            # no akasha-admin session left
```

## 6. Each laptop: sign in as `akasha-l0`

```bash
aws login --profile akasha-l0 --region eu-west-3             # browser: akasha-l0 + MFA
```

Partial backend configuration for OpenTofu, private (`~/akasha-private/l0.s3.tfbackend`, mode
600); credentials are not put in it, OpenTofu reads them from `AWS_PROFILE=akasha-l0`:

```hcl
bucket       = "<bucket>"
key          = "l0/terraform.tfstate"
region       = "eu-west-3"
use_lockfile = true
```

## 7. Check as `akasha-l0` — only before the first L0 apply

These tests write the lock object without OpenTofu's conditional write: **never run them once
an L0 state exists**, they could overwrite a real lock. IAM changes take a few seconds to
spread: if a check fails right after step 4, wait and retry.

```bash
export AWS_PROFILE=akasha-l0 AWS_REGION=eu-west-3; . ~/akasha-private/aws-l0-state.env
m() { sed "s/$ACCOUNT/<account>/g; s/$BUCKET/<bucket>/g"; }
aws sts get-caller-identity --query Arn --output text | m    # …:user/akasha-l0
t=$(mktemp); echo test > "$t"; L="$KEY.tflock"
v=$(aws s3api put-object --bucket "$BUCKET" --key "$L" --body "$t" --query VersionId --output text)
aws s3api delete-object --bucket "$BUCKET" --key "$L" --version-id "$v" 2>&1 \
  | grep -qE 'AccessDenied|403' && echo "ok: deleting a version is denied"
aws s3api delete-object --bucket "$BUCKET" --key "$L" >/dev/null && echo "ok: lock can be released"
aws s3api head-object --bucket "$BUCKET" --key "$KEY" 2>&1 \
  | grep -qE '404|Not Found' && echo "ok: empty state reads as not found (tofu init will work)"
aws s3 cp "$t" "s3://$BUCKET/other" 2>&1 | grep -qE 'AccessDenied|403' && echo "ok: other keys denied"
rm -f "$t"
```

Each line must print its `ok:` message; a missing line is a failed check. A 403 instead of 404
on `head-object` means `s3:ListBucket` is missing and `tofu init` would fail.

## Roll back

This destroys the L0 state and its history. Only after the owner confirms, and after checking
that an off-AWS copy of the latest encrypted state exists. As `akasha-admin`, in bash:

```bash
aws login --profile akasha-admin --region eu-west-3; export AWS_PROFILE=akasha-admin
. ~/akasha-private/aws-l0-state.env; w=$(umask 077; mktemp -d)
for k in Versions DeleteMarkers; do                           # up to 1000 per call: repeat
  aws s3api list-object-versions --bucket "$BUCKET" --output json \
    --query "{Objects:($k||\`[]\`)[].{Key:Key,VersionId:VersionId}}" > "$w/d.json"
  grep -q VersionId "$w/d.json" && aws s3api delete-objects --bucket "$BUCKET" --delete "file://$w/d.json"
done
aws s3api delete-bucket --bucket "$BUCKET"
aws iam detach-user-policy --user-name akasha-l0 --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess
aws iam detach-user-policy --user-name akasha-l0 --policy-arn "arn:aws:iam::$ACCOUNT:policy/akasha-l0-state"
aws iam delete-login-profile --user-name akasha-l0
# in the console: deactivate and delete the MFA device of akasha-l0
aws iam delete-user --user-name akasha-l0
aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT:policy/akasha-l0-state"
rm -rf "$w"; aws logout --profile akasha-admin
```

On each laptop: `aws logout --profile akasha-l0`. `akasha-admin` is kept (it is the account's
administrator, not part of the L0 state).
