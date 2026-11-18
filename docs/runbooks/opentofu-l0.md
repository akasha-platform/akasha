# OpenTofu L0 stack (`infra/opentofu/live/l0-host`)

Design: [ADR-0007](../adr/0007-opentofu-and-providers.md),
[ADR-0031](../adr/0031-l0-state-in-aws-s3.md), [ADR-0032](../adr/0032-ci-states-in-aws-s3.md).
Only the owner runs this stack, from the laptop, in an unlocked desktop session. The state is
in the L0 bucket (created with [aws-l0-state.md](aws-l0-state.md)), encrypted client-side
with a passphrase kept in the desktop keyring (GNOME Keyring) and on paper.

## Once: create the passphrase

In your own terminal, not inside an agent or a recorded session:

```bash
cd ~/Documents/dev/Projets/akasha && eval "$(mise activate bash)"
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --init l0
# write the 8 groups on paper, then:
clear; printf '\e[3J'
uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --verify l0   # type it back from paper
```

`--init` generates a 64-character passphrase from letters and digits that are easy to read back
(no 0/O, 1/l/I), stores it in GNOME Keyring (service `akasha-opentofu`, user `l0`) and shows it
once. It refuses to replace an existing passphrase. `--check l0` tells whether it exists;
`--restore l0` stores a paper copy again if the keyring lost it. The script only uses the
desktop's Secret Service and gives up after 45 s (for example when the keyring is locked and
its unlock prompt is not answered). Keep `TF_ENCRYPTION` unset: it would be merged into the
stack's encryption configuration.

Without this passphrase the state cannot be read: losing both the laptop's keyring and the
paper means rebuilding the state by import (ADR-0031).

## Every session

```bash
cd ~/Documents/dev/Projets/akasha && eval "$(mise activate bash)"
aws login --profile akasha-l0 --region eu-west-3       # when the session has expired
export AWS_PROFILE=akasha-l0 AWS_REGION=eu-west-3
cd infra/opentofu/live/l0-host
tofu init -input=false -backend-config="$HOME/akasha-private/l0.s3.tfbackend"   # once per checkout
tofu plan -out=l0.plan
tofu apply l0.plan
```

The plan file is encrypted too (`enforced`), and `*.plan` is git-ignored. OpenTofu calls the
passphrase script through `mise exec`, so the pinned uv and the locked environment are used.

## Checks of the first run (step 6a)

```bash
. ~/akasha-private/aws-l0-state.env; s=$(umask 077; mktemp -p ~/akasha-private)
aws s3api get-object --bucket "$BUCKET" --key l0/terraform.tfstate "$s" >/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sorted(d), sorted(d['meta']))" "$s"
# ['encrypted_data', 'encryption_version', 'lineage', 'meta', 'serial'] ['l0-passphrase', 'l0-pbkdf2']
rm -f "$s"
```

Only `lineage` (the state's identifier), `serial` (its write counter) and the key-provider
metadata (pbkdf2 salt and parameters) are in clear.

Lock: in terminal 1 run `tofu console` (it holds the state lock until you leave it); in
terminal 2, `tofu plan` must stop with `Error acquiring the state lock`. Leave the console
with `exit`.

## Off-AWS copy after every apply

```bash
. ~/akasha-private/aws-l0-state.env
aws s3 cp "s3://$BUCKET/l0/terraform.tfstate" \
  ~/akasha-private/backups/l0-terraform.tfstate.$(date -u +%Y%m%dT%H%M%SZ)
```

The copy is the encrypted object (never the output of `tofu state pull`, which is
decrypted). It is still on the laptop: copy it to another medium from time to time.

## Provider supply chain

The OpenTofu registry has no GPG key for `dmacvicar/libvirt`, so `tofu init` prints
"Signature validation was skipped". On 2026-11-18 the 0.9.9 release was checked by hand: its
`SHA256SUMS` carries a good signature from Duncan Mac-Vicar (key
`F6D3 7375 0D6F 5983 E706 34DC 0833 E38C 51E7 4D26`, published on the Terraform registry), and
all 13 `zh:` hashes of `.terraform.lock.hcl` match that file. Repeat this check whenever the
provider version changes.

## Rotate the passphrase

Add a second chain (`external "passphrase_v2"` calling the script with `l0-v2`, a `pbkdf2`
and an `aes_gcm` method with new aliases), point `state` and `plan` at the new method with
`fallback { method = method.aes_gcm.l0 }`, run `--init l0-v2`, then a plan and an apply: the
state is re-encrypted with the new key. Then remove the old chain and its keyring entry.

## Roll back (step 6a: empty state)

As `akasha-admin`: delete the object `l0/terraform.tfstate` (all versions) from the bucket.
In the keyring (Seahorse, "Passwords and Keys"): delete `akasha-opentofu` / `l0`.
