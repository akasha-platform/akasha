---
status: accepted
date: 2026-11-09
decision-makers: dhuy21
---

# Repository layout

## Context and Problem Statement

The TD2 tree (`terraform/`, `ansible/`, `helm/` at the root) does not fit a multi-layer
platform. The new layout must separate tools and layers, keep application code next to its
chart, and avoid suggesting the wrong IaC tool (open question B7).

## Considered Options

* IaC folder: `infra/opentofu/` · `infra/terraform/` · `infra/tofu/`
* Keep TD2 in a `legacy/` folder · tag it and remove it from the tree

## Decision Outcome

* TD2 is preserved at annotated tag `td2-final` (commit `4e6ac89`) and removed from the tree.
* Top-level layout:

  ```
  infra/opentofu/   one root module per layer under live/, shared code under modules/
  infra/ansible/    inventories, playbooks, roles, pinned collections
  infra/kolla/      Kolla-Ansible --configdir (no plaintext passwords.yml)
  apps/novashop/    src/, Dockerfile, chart/
  docs/             adr/, architecture/, research/, runbooks/, roadmap, open questions
  ```

* The IaC folder is named **`infra/opentofu/`** after the tool actually used (ADR-0007).
* Folders are created when the phase that needs them starts; each existing folder has a README
  describing what it will contain.
* `akasha-gitops` gets its own layout in phase P5 (bootstrap, ApplicationSets, platform, apps).
* Licence: Apache-2.0, copyright Dinh Huy NGUYEN. `SECURITY.md` points to GitHub private
  vulnerability reporting.

### Consequences

* Good, because the tree mirrors the layers of the architecture and the tool names.
* Neutral: the TD2 code is only one `git checkout td2-final` away.
