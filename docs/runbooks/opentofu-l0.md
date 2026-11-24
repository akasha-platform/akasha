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
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"   # key allowed on the lab VMs
cd infra/opentofu/live/l0-host
tofu init -input=false -backend-config="$HOME/akasha-private/l0.s3.tfbackend"   # once per checkout
tofu plan -out=l0.plan
tofu apply l0.plan
```

The plan file is encrypted too (`enforced`), and `*.plan` is git-ignored. OpenTofu calls the
passphrase script through `mise exec`, so the pinned uv and the locked environment are used.

## Base images

Before an apply that creates a VM, fetch and check the pinned images (ADR-0033):

```bash
uv run --locked python infra/opentofu/scripts/fetch_image.py debian13
```

The image is kept in `~/.cache/akasha/images/` only if its size and SHA-512 match
`infra/opentofu/live/l0-host/images.json`; OpenTofu refuses a cached file that does not match.

## VMs (step 6b on)

After every apply, a second `tofu plan` must show **no change**: any domain change restarts
the VM. Look at a VM from `insa` (the owner is in the `libvirt` group):

```bash
virsh -c qemu:///system list --all
virsh -c qemu:///system dumpxml router | less
virsh -c qemu:///system console router          # leave with Ctrl+]
sudo tail -n 50 /var/log/libvirt/qemu/router-serial.log   # the whole console output (every boot)
```

**A VM resets in a loop right after GRUB's `Booting 'Debian GNU/Linux'`**, with no
`Loading Linux` line in its serial log: it has no video device (ADR-0034). Check
`virsh -c qemu:///system dumpxml <vm> | grep -A2 '<video'`.

**After a host reboot** the VMs stay off (ADR-0033): check that `lv_images` is mounted
(`findmnt /var/lib/libvirt/akasha`; without it the pool `akasha` cannot start, by design), run
the checks of `host-firewall.md` ("Check after every reboot"), then
`virsh -c qemu:///system start router`, then the other VMs.

**Destroying the whole stack** on purpose: the base images carry `prevent_destroy`; remove that
line in `images.tf` first.

**Rebuilding one VM** (done for the router in step 6b-4):

1. Record what must come back: `virsh -c qemu:///system dumpxml <vm>`, the VM's managed files,
   and the length of its serial log (runbook `lab-vms.md`, "Add a lab VM").
2. Make an off-AWS copy of the state.
3. Destroy through a saved plan, so that what you read is what runs. The confirmation prompt
   of `tofu destroy` says "destroy all resources" even with `-target`: judge by the list.
   Expect `libvirt_domain.this`, `libvirt_volume.root`, `libvirt_volume.seed` and possibly
   `libvirt_cloudinit_disk.seed` (it is only in the state while its ISO is still in the
   laptop's temporary directory), all under `module.<vm>.`, and nothing else.

   ```bash
   tofu plan -destroy -target=module.<vm> -no-color -out=destroy.plan 2>&1 | grep -E '^  # |^Plan:|Error'
   tofu apply -no-color destroy.plan; rm -f destroy.plan
   ```

4. Check that nothing is left, then copy the state again.

   ```bash
   ssh -t insa 'virsh -c qemu:///system list --all; virsh -c qemu:///system vol-list akasha; sudo ls -la /var/lib/libvirt/akasha/pool'
   ```

5. `tofu plan -out=l0.plan` (only `module.<vm>.` resources to add), `tofu apply l0.plan`, then
   a second plan with no change. Copy the state.
6. Check the new host key (runbook `lab-vms.md`), and run the VM's playbook twice.

Paste only filtered output (`grep` as above): a full plan prints the SSH key's comment in the
user-data, and `aws s3 cp` prints the bucket name unless it is given `--only-show-errors`.

**A23 drill** (provider 0.9.9 keeps the cloud-init ISO in the laptop's temp directory): delete
`${TMPDIR:-/tmp}/terraform-provider-libvirt-cloudinit/`, run `tofu plan`: it may recreate the
`libvirt_cloudinit_disk` (local only) but must not replace a volume nor update a domain.

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
