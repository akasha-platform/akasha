"""OpenTofu external key provider: the state passphrase from the desktop keyring (ADR-0031).

OpenTofu runs it from a stack directory (see encryption.tf there):

    mise exec -- uv run --locked --quiet python ../../scripts/tofu_passphrase.py <name>

It speaks OpenTofu's external key provider protocol on stdin/stdout and returns the
passphrase stored in the keyring under service ``akasha-opentofu`` and user ``<name>``;
OpenTofu's pbkdf2 key provider derives the encryption key from it. When the passphrase is
missing it fails, so no state is ever written with another key.

Only the desktop's Secret Service (GNOME Keyring) is used: the backend is pinned, so neither
PYTHON_KEYRING_BACKEND nor a keyringrc file nor another installed backend can redirect it.
The script gives up after TIMEOUT seconds (an unanswered unlock prompt would otherwise hang
OpenTofu, whose own timeout does not stop the child behind mise and uv).

Modes, run in a desktop session (docs/runbooks/opentofu-l0.md):

    uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --init <name>
    uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --check <name>
    uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --verify <name>
    uv run --locked python infra/opentofu/scripts/tofu_passphrase.py --restore <name>

--init generates and stores a passphrase and shows it once, in groups, for the paper copy;
--check tells whether it exists; --verify asks for it (typed from paper) and compares;
--restore stores a passphrase typed from paper when the keyring lost it.
"""

import argparse
import base64
import getpass
import hmac
import json
import secrets
import signal
import sys

from keyring.backends import SecretService

SERVICE = "akasha-opentofu"
MIN_LENGTH = 32
TIMEOUT = 45  # seconds, below OpenTofu's one-minute limit
HEADER = {"magic": "OpenTofu-External-Key-Provider", "version": 1}


def fail(message: str) -> None:
    print(f"tofu_passphrase: {message}", file=sys.stderr)
    sys.exit(1)


def on_timeout(signum, frame) -> None:
    fail(f"timed out after {TIMEOUT} s waiting for the keyring (locked or prompting?)")


def keyring_call(action):
    """Run one Secret Service operation with a time limit; any failure stops the script."""
    signal.signal(signal.SIGALRM, on_timeout)
    signal.alarm(TIMEOUT)
    try:
        # Pinned backend: PYTHON_KEYRING_BACKEND, keyringrc files and other installed backends
        # are never consulted. `priority` raises when the service is not usable.
        SecretService.Keyring.priority  # noqa: B018
        return action(SecretService.Keyring())
    except Exception as error:  # KeyringError, RuntimeError, D-Bus errors: all fail closed
        fail(f"cannot use the desktop keyring ({type(error).__name__}: {error}); "
             "run it in an unlocked desktop session")
    finally:
        signal.alarm(0)


def read_passphrase(name: str) -> str:
    value = keyring_call(lambda kr: kr.get_password(SERVICE, name))
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
    json.loads(sys.stdin.read() or "null")  # validated, not needed: the passphrase is fixed
    key = base64.b64encode(read_passphrase(name).encode()).decode("ascii")
    # 3. Output: the same passphrase for both directions (pbkdf2 stores its own salt). The
    # decryption key is always returned: pbkdf2 ignores it when it only encrypts, and a
    # missing one would turn a metadata problem into a misleading authentication error.
    keys = {"encryption_key": key, "decryption_key": key}
    sys.stdout.write(json.dumps({"keys": keys, "meta": {"external_data": {}}}))
    sys.stdout.flush()


# Letters and digits that are easy to read back from paper: no 0/O, 1/l/I, no symbols.
ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def store(name: str, value: str) -> None:
    keyring_call(lambda kr: kr.set_password(SERVICE, name, value))
    if keyring_call(lambda kr: kr.get_password(SERVICE, name)) != value:
        fail("the keyring did not return the stored passphrase")


def existing(name: str) -> bool:
    return bool(keyring_call(lambda kr: kr.get_password(SERVICE, name)))


def typed() -> str:
    value = getpass.getpass("Passphrase (from paper, spaces ignored): ").replace(" ", "")
    if len(value) < MIN_LENGTH:
        fail(f"shorter than {MIN_LENGTH} characters")
    return value


def init(name: str) -> None:
    if existing(name):
        fail(f"a passphrase for '{name}' already exists; it is never replaced by --init")
    value = "".join(secrets.choice(ALPHABET) for _ in range(64))  # about 373 bits
    store(name, value)
    print(f"Stored in the keyring as service '{SERVICE}', user '{name}'.")
    print("Write it on paper now (groups of 8, spaces are not part of it), then run")
    print("`clear; printf '\\e[3J'` and check the copy with --verify:")
    print(" ".join(value[i : i + 8] for i in range(0, len(value), 8)))


def check(name: str) -> None:
    read_passphrase(name)
    print(f"ok: a passphrase for '{name}' exists in the keyring")


def verify(name: str) -> None:
    if hmac.compare_digest(typed(), read_passphrase(name)):
        print("ok: the paper copy matches the keyring")
    else:
        fail("the paper copy does NOT match the keyring")


def restore(name: str) -> None:
    if existing(name):
        fail(f"a passphrase for '{name}' already exists; delete it in the keyring first")
    value = typed()
    if not hmac.compare_digest(value, typed()):
        fail("the two entries differ")
    store(name, value)
    print(f"ok: stored in the keyring as service '{SERVICE}', user '{name}'")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--init", action="store_true", help="generate and store the passphrase")
    mode.add_argument("--check", action="store_true", help="check that the passphrase exists")
    mode.add_argument("--verify", action="store_true", help="compare a typed paper copy")
    mode.add_argument("--restore", action="store_true", help="store a typed paper copy")
    parser.add_argument("name", help="stack name, e.g. l0")
    args = parser.parse_args()
    if args.init:
        init(args.name)
    elif args.check:
        check(args.name)
    elif args.verify:
        verify(args.name)
    elif args.restore:
        restore(args.name)
    else:
        provide(args.name)


if __name__ == "__main__":
    main()
