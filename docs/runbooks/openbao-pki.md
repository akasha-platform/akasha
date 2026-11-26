# OpenBao's configuration with OpenTofu: the intermediate CA

Design: [ADR-0046](../adr/0046-openbao-pki-intermediate.md); the admin's token settings:
[ADR-0047](../adr/0047-openbao-tls-and-network-access.md). Stack
`infra/opentofu/live/openbao/`, applied by the owner only, from the laptop, through an SSH
tunnel to OpenBao's loopback listener on `core`. The state lives in the L0 bucket under
`openbao/terraform.tfstate`, encrypted with the passphrase `openbao` of the desktop keyring.

| File | Where | Secret |
|---|---|---|
| Intermediate CSR and signed certificate | `infra/pki/akasha-intermediate-ca.{csr,crt}` | no |
| Extensions the root gives the intermediate | `infra/pki/intermediate-ca.ext` | no |
| Partial backend configuration | `~/akasha-private/openbao.s3.tfbackend` | private (bucket name) |
| The intermediate's key | inside OpenBao only (`type = "internal"`) | yes, never exported |

## Once: AWS policy, backend configuration, passphrase

Extend the policy of `akasha-l0` to the new key (as `akasha-admin`, runbook `aws-l0-state.md`
step 2 for the variables and `m`):

```bash
aws login --profile akasha-admin --region eu-west-3
export AWS_PROFILE=akasha-admin AWS_REGION=eu-west-3; . ~/akasha-private/aws-l0-state.env
m() { sed "s/$ACCOUNT/<account>/g; s/$BUCKET/<bucket>/g"; }
w=$(umask 077; mktemp -d); K2=openbao/terraform.tfstate
cat > "$w/state.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"ListBucket","Effect":"Allow","Action":"s3:ListBucket",
  "Resource":"arn:aws:s3:::$BUCKET"},
 {"Sid":"State","Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],
  "Resource":["arn:aws:s3:::$BUCKET/$KEY","arn:aws:s3:::$BUCKET/$K2"]},
 {"Sid":"Lock","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],
  "Resource":["arn:aws:s3:::$BUCKET/$KEY.tflock","arn:aws:s3:::$BUCKET/$K2.tflock"]}]}
EOF
arn="arn:aws:iam::$ACCOUNT:policy/akasha-l0-state"
aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[].[VersionId,IsDefaultVersion]' --output text
aws iam create-policy-version --policy-arn "$arn" --policy-document "file://$w/state.json" \
  --set-as-default --query PolicyVersion.VersionId --output text
aws iam get-policy-version --policy-arn "$arn" \
  --version-id "$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)" \
  --query 'PolicyVersion.Document.Statement[].Resource' | m
```

Roll back: `aws iam set-default-policy-version --policy-arn "$arn" --version-id <previous>`.

```bash
(umask 077; sed 's#^key .*#key          = "openbao/terraform.tfstate"#' ~/akasha-private/l0.s3.tfbackend \
  > ~/akasha-private/openbao.s3.tfbackend); grep key ~/akasha-private/openbao.s3.tfbackend
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --init openbao     # write it on paper
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --verify openbao   # type it back from paper
```

## Every session

```bash
cd ~/Documents/dev/Projets/akasha && eval "$(mise activate bash)" && set -o pipefail
aws login --profile akasha-l0 --region eu-west-3        # when the session has expired
export AWS_PROFILE=akasha-l0 AWS_REGION=eu-west-3
# The tunnel, in the background: OpenBao's plain loopback listener, reached through SSH only.
ssh -f -N -o ExitOnForwardFailure=yes -o BatchMode=yes -L 127.0.0.1:8200:127.0.0.1:8200 debian@10.10.0.12
# The admin's token (1 h), from the age-encrypted password; asks for the age passphrase.
P=~/akasha-private/openbao; AGE=$(mise which age)
export VAULT_TOKEN=$("$AGE" -d -i $P/identity.age $P/admin-password.age \
  | ssh -o BatchMode=yes debian@10.10.0.12 'BAO_ADDR=http://127.0.0.1:8200 bao login -method=userpass -token-only -no-store username=admin password=-')
test -n "$VAULT_TOKEN" && echo "token ok"
cd infra/opentofu/live/openbao
tofu init -input=false -backend-config="$HOME/akasha-private/openbao.s3.tfbackend"   # once per checkout
tofu plan -out=openbao.plan && tofu apply openbao.plan
```

End of session: revoke the token (header from stdin, never on a command line), close the tunnel:

```bash
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" | curl -sS -H @- -X POST -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8200/v1/auth/token/revoke-self                           # 204
unset VAULT_TOKEN; pkill -f -- '-L 127.0.0.1:8200:127.0.0.1:8200 debian@10.10.0.12'
```

The token is in the shell's environment until then: other processes of the same user can read
it (`/proc/<pid>/environ`). Keep the session short.

## The intermediate CA (done once, step 7d-1)

1. First apply: mount `pki`, URLs, role `server`, and the CSR. Save the CSR:

   ```bash
   tofu output -raw intermediate_csr > ../../../pki/akasha-intermediate-ca.csr
   openssl req -in ../../../pki/akasha-intermediate-ca.csr -noout -verify -subject   # O=akasha, CN=akasha Intermediate CA
   ```

2. Sign it with the offline root (runbook `pki-root-ca.md`), swap off, from the repository:

   ```bash
   cd ~/Documents/dev/Projets/akasha && sudo swapoff -a && swapon --show && echo "swap off"
   test ! -e infra/pki/akasha-intermediate-ca.crt && mise exec -- age -d ~/akasha-private/pki/root-ca.key.age \
     | openssl x509 -req -in infra/pki/akasha-intermediate-ca.csr -CA infra/pki/akasha-root-ca.crt -CAkey /dev/stdin \
         -set_serial "0x$(openssl rand -hex 16)" -days 1826 -sha384 -extfile infra/pki/intermediate-ca.ext \
         -out infra/pki/akasha-intermediate-ca.crt
   sudo swapon -a && swapon --show
   openssl verify -CAfile infra/pki/akasha-root-ca.crt infra/pki/akasha-intermediate-ca.crt
   openssl x509 -in infra/pki/akasha-intermediate-ca.crt -noout -subject -issuer -dates -ext basicConstraints,keyUsage
   ```

3. Second apply: `set_signed` imports the certificate and the root. Then `tofu plan` shows no
   changes.

## Check

Through the tunnel, with the token from stdin:

```bash
h() { printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN"; }
A=http://127.0.0.1:8200/v1
h | curl -sS -H @- $A/pki/config/issuers | jq -c .data                      # default = the intermediate
# A one-hour test certificate, kept in a shell variable only: its key is never written.
r=$(h | curl -sS -H @- -X POST -d '{"common_name":"test.akasha.internal","ttl":"1h"}' $A/pki/issue/server)
openssl verify -CAfile ~/Documents/dev/Projets/akasha/infra/pki/akasha-root-ca.crt \
  -untrusted <(jq -r '.data.ca_chain[]' <<<"$r") <(jq -r .data.certificate <<<"$r")   # OK
s=$(jq -r .data.serial_number <<<"$r")
h | curl -sS -H @- -X POST -d "{\"serial_number\":\"$s\"}" $A/pki/revoke | jq -c .data   # revocation_time
unset r s
h | curl -sS -H @- -X POST -d '{"common_name":"example.com"}' $A/pki/issue/server | jq -r '.errors[0]'   # not allowed
```

## Off-AWS copy after every apply

```bash
. ~/akasha-private/aws-l0-state.env
aws s3 cp --only-show-errors "s3://$BUCKET/openbao/terraform.tfstate" \
  ~/akasha-private/backups/openbao-terraform.tfstate.$(date -u +%Y%m%dT%H%M%SZ)
```

## Provider supply chain

`hashicorp/vault` is signed by HashiCorp (key ID `0C0AF313E5FD9F80`); `tofu init` checks the
signature and `.terraform.lock.hcl` pins its hashes. Renovate proposes new versions (ADR-0024);
check each against OpenBao before merging (OpenBao is not Vault: ADR-0046).

## Failure modes

* **The admin's settings** (`auth.tf`): the stack writes the token fields of the user `admin`
  (bound to 127.0.0.1, TTLs, policy), never its password, and never deletes it. A wrong
  `token_bound_cidrs` would lock the admin out of every path, the tunnel included: then make a
  root token from two shares on `core` (runbook `core.md`, "Admin locked out"), fix, revoke it.
  The plan shows `data_json` as `(sensitive value)`; check the values with
  `bao read auth/userpass/users/admin` on `core`.
* **`tofu` cannot reach OpenBao**: the tunnel is down (`ss -ltn | grep 8200`), or OpenBao is
  sealed (runbook `core.md`, "Unseal").
* **403 permission denied**: the token expired (1 h, 4 h at most); log in again.
* **`prevent_destroy`** stops a plan: something would delete or replace the mount or the CSR,
  and with them the intermediate's key. Never remove the guard to get past it; find what
  changed.
* **The intermediate expires on the date in `akasha-intermediate-ca.crt`** (5 years): make a
  new CSR with a new `key_name`, sign it with the root, and import it well before.
