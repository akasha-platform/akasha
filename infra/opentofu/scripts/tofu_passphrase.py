"""OpenTofu external key provider: the state passphrase from the desktop keyring (ADR-0031).

OpenTofu runs it from a stack directory (see encryption.tf there):

    mise exec -- uv run --locked --quiet python ../../scripts/tofu_passphrase.py <name>

It speaks OpenTofu's external key provider protocol on stdin/stdout and returns the
passphrase stored in the keyring under service ``akasha-opentofu`` and user ``<name>``;
OpenTofu's pbkdf2 key provider derives the encryption key from it. When the passphrase is
missing it fails, so no state is ever written with another key.

The owner creates the passphrase once, in a desktop session (docs/runbooks/opentofu-l0.md):

    uv run python infra/opentofu/scripts/tofu_passphrase.py --init <name>

which generates it, stores it in the keyring and shows it once for the paper copy.
``--check <name>`` tells whether it exists without showing it.
"""

import argparse
import base64
import json
import secrets
import sys

import keyring
from keyring.errors import KeyringError

SERVICE = "akasha-opentofu"
MIN_LENGTH = 32
HEADER = {"magic": "OpenTofu-External-Key-Provider", "version": 1}


def fail(message: str) -> None:
    print(f"tofu_passphrase: {message}", file=sys.stderr)
    sys.exit(1)


def read_passphrase(name: str) -> str:
    try:
        value = keyring.get_password(SERVICE, name)
    except KeyringError as error:
        fail(f"cannot read the keyring ({error}); run it in an unlocked desktop session")
    if not value:
        fail(f"no passphrase for '{name}' in the keyring (service {SERVICE}); see the runbook")
    if len(value) < MIN_LENGTH:
        fail(f"the passphrase for '{name}' is shorter than {MIN_LENGTH} characters")
    return value


def provide(name: str) -> None:
    # 1. Header first, so OpenTofu knows this is a key provider.
    sys.stdout.write(json.dumps(HEADER) + "\n")
    sys.stdout.flush()
    # 2. Input: null when OpenTofu only encrypts, the stored metadata when it also decrypts.
    request = json.loads(sys.stdin.read() or "null")
    key = base64.b64encode(read_passphrase(name).encode()).decode("ascii")
    keys = {"encryption_key": key}
    if request is not None:
        keys["decryption_key"] = key
    # 3. Output: the same passphrase for both directions; pbkdf2 stores its own salt.
    sys.stdout.write(json.dumps({"keys": keys, "meta": {"external_data": {}}}))
    sys.stdout.flush()


def init(name: str) -> None:
    if keyring.get_password(SERVICE, name):
        fail(f"a passphrase for '{name}' already exists; it is never replaced by this script")
    value = secrets.token_urlsafe(48)  # 64 characters, 384 bits
    keyring.set_password(SERVICE, name, value)
    if keyring.get_password(SERVICE, name) != value:
        fail("the keyring did not return the stored passphrase")
    print(f"Stored in the keyring as service '{SERVICE}', user '{name}'.")
    print("Write it on paper now, then run `clear` (it is not saved in the shell history):")
    print(value)


def check(name: str) -> None:
    read_passphrase(name)
    print(f"ok: a passphrase for '{name}' exists in the keyring")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--init", action="store_true", help="generate and store the passphrase")
    mode.add_argument("--check", action="store_true", help="check that the passphrase exists")
    parser.add_argument("name", help="stack name, e.g. l0")
    args = parser.parse_args()
    if args.init:
        init(args.name)
    elif args.check:
        check(args.name)
    else:
        provide(args.name)


if __name__ == "__main__":
    main()
