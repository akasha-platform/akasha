# Offline root CA

Design: [ADR-0044](../adr/0044-offline-root-ca.md). The root signs only OpenBao's intermediate
CA (step 7d). Everything here runs on the owner's laptop, from the repository's root, with the
pinned toolchain (`mise exec -- age`).

| File | Where | Secret |
|---|---|---|
| Configuration | `infra/pki/root-ca.cnf` | no |
| Certificate | `infra/pki/akasha-root-ca.crt` | no |
| Key, encrypted with age | `~/akasha-private/pki/root-ca.key.age` | yes, never commit |

The passphrase: in the owner's head, plus a handwritten copy kept away from the laptop.
Fingerprint (SHA-256) of the root made on 2026-11-25:
`61:C1:73:BA:8C:32:AE:63:0A:BC:08:06:88:55:E2:7B:26:65:C1:D6:7D:D8:94:FE:4A:79:64:F1:24:9F:0A:C6`.

## Check

```bash
openssl x509 -in infra/pki/akasha-root-ca.crt -noout -subject -dates -fingerprint -sha256 \
  -ext basicConstraints,keyUsage,nameConstraints
# The key still opens, and is the certificate's (asks for the passphrase):
mise exec -- age -d ~/akasha-private/pki/root-ca.key.age | openssl pkey -pubout \
  | cmp - <(openssl x509 -in infra/pki/akasha-root-ca.crt -noout -pubkey) && echo "key matches certificate"
```

## Use the key (sign the intermediate, step 7d)

The key goes from `age -d` into a pipe, never into a file. Turn swap off first (the laptop's
disk is not encrypted), and turn it on again afterwards:

```bash
sudo swapoff -a && swapon --show && echo "swap off"
mise exec -- age -d ~/akasha-private/pki/root-ca.key.age | openssl x509 -req -CAkey /dev/stdin \
  -CA infra/pki/akasha-root-ca.crt -in <csr> -out <certificate> ...   # exact command in 7d
sudo swapon -a && swapon --show
```

## Make the root (done once, 2026-11-25)

```bash
sudo swapoff -a && swapon --show && echo "swap off"
umask 077 && mkdir -p ~/akasha-private/pki
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  | mise exec -- age -p -o ~/akasha-private/pki/root-ca.key.age     # type the passphrase
mise exec -- age -d ~/akasha-private/pki/root-ca.key.age \
  | openssl req -x509 -new -config infra/pki/root-ca.cnf -key /dev/stdin -sha384 -days 3650 \
      -out infra/pki/akasha-root-ca.crt
# The "Check" above, with the passphrase read from the paper copy.
sudo swapon -a && swapon --show
```

Give `age -p` a passphrase of your own. Left empty, age generates a random one.

## Failure modes

* **Passphrase forgotten and paper copy lost.** The key cannot be recovered. Make a new root,
  and replace the intermediate and the trust on every client.
* **Laptop lost before step 7e** (the backup of `~/akasha-private` to S3). Same as above.
* **Key leaked** (the age file and the passphrase). Remove the root from every client's trust
  store, make a new one, and re-issue the intermediate and every certificate.
* **A certificate fails with "permitted subtree violation".** Its name or address lies outside
  `akasha.internal`, `cluster.local` and `10.0.0.0/8`. Use a name inside them; widening the
  constraints means a new root.
* **The root expires on 2036-11-22.** Make a new root well before, and distribute it next to
  the old one.
