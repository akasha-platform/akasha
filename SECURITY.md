# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub:
[Report a vulnerability](https://github.com/akasha-platform/akasha/security/advisories/new)
(Security → Advisories). Do not open a public issue.

You can expect an acknowledgement within 7 days. This is a personal portfolio project, so
there is no bug bounty.

## Scope

- Code and configuration in this repository and in
  [`akasha-gitops`](https://github.com/akasha-platform/akasha-gitops).
- Supply-chain issues in the CI workflows (actions, runners, image signing).

The lab itself is not exposed to the Internet; access is limited to a private Tailscale
network. Reports about infrastructure that is not described in these repositories are out of
scope.

## Practices in place

- Secret scanning with push protection on both repositories.
- GitHub Actions pinned to full commit SHAs; read-only default token; workflows from fork pull
  requests require approval and never reach the lab.
- No secrets in Git: secrets live in OpenBao; state files are encrypted.

## Known historical note

The Git history before tag `td2-final` contains throw-away passwords of the original school
lab. That environment is being destroyed and those values are never reused.
