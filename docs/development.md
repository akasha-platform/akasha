# Development setup

The toolchain is pinned and verified ([ADR-0022](adr/0022-pinned-toolchain.md)). Tools
installed system-wide are not affected: mise and uv only apply inside this repository.

## One-time setup (Ubuntu)

```bash
sudo add-apt-repository -y ppa:jdxcode/mise
sudo apt update && sudo apt install -y mise
echo 'eval "$(mise activate bash)"' >> ~/.bashrc && exec bash
mise --version            # must be >= 2026.11.1
```

## In the repository

```bash
mise trust                # allow mise to read this repo's mise.toml (once)
mise install --locked     # binaries exactly as described by mise.lock
uv sync --locked          # Python tools exactly as described by uv.lock (.venv/)
```

Run Python tools with `uv run <tool>` (e.g. `uv run ansible-lint`). The first `uv sync`
downloads the pinned CPython (3.14.10); the system Python is never used. If `uv` reports
"Required uv version … does not match", the shell is not using mise's uv — open a new terminal
or run `mise exec -- uv …`.

## Checks (git hook and CI)

```bash
uv run pre-commit install          # once per clone: run the checks on every `git commit`
uv run pre-commit run --all-files  # run every check on the whole repository
```

The same list (`.pre-commit-config.yaml`) runs in CI (`.github/workflows/lint.yml`,
ADR-0023). Commits on `main` are refused locally: work on a branch and open a pull request.
New files are only checked once they are staged (`git add`).

## Ansible

Host configuration lives in `infra/ansible/` (ADR-0026). Once per clone, and after a
collection bump:

```bash
cd infra/ansible
uv run ansible-galaxy collection install -r collections/requirements.yml -p collections
```

The inventory uses the SSH alias `insa` from your `~/.ssh/config` (Tailscale). Always dry-run
first: `uv run ansible-playbook playbooks/<name>.yml --check --diff -K`.

## Signed commits

`main` accepts only signed commits (ADR-0025): a pull request containing an unsigned commit
cannot be merged. Sign with a dedicated SSH key, once per machine:

```bash
ssh-keygen -t ed25519 -C "git signing (<you>, <machine>)" -f ~/.ssh/id_ed25519_signing
ssh-add ~/.ssh/id_ed25519_signing
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
mkdir -p ~/.config/git
printf '%s namespaces="git" %s\n' "$(git config --global user.email)" \
  "$(cat ~/.ssh/id_ed25519_signing.pub)" >> ~/.config/git/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
```

Add the public key on GitHub as a **Signing Key** (Settings → SSH and GPG keys → New SSH key →
Key type). The committer e-mail must be a verified address of the account. Check a commit with
`git log --show-signature -1`.

## Updating a tool

Renovate proposes updates as pull requests (ADR-0024; dependency dashboard issue in the
repository). Review them like any other pull request, with the checks below. By hand:

1. Pick the newest release published **at least 6 days ago**.
2. Change the version in `mise.toml`, run `mise lock --platform linux-x64`, review the diff.
3. If the tool has no publisher signature (gitleaks, shellcheck) or mise records no provenance
   (OpenTofu), compare the new checksum with the release's official checksum file and, for
   OpenTofu, run `cosign verify-blob` with the identity published in the OpenTofu docs.
4. `mise install --locked`, check the version, open a pull request.

Python tools: `exclude-newer = "6 days"` in `pyproject.toml` keeps every package at least 6 days
old whenever the lock is re-resolved; run `uv lock --upgrade-package <name>` (or `uv lock
--upgrade`), review `uv.lock`, then `uv sync --locked`. Python itself: change `.python-version` to a patch
release whose standalone build is at least 6 days old. uv: change `mise.toml` and
`required-version` in `pyproject.toml` together.
