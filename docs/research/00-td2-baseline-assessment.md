# 00 — TD2 baseline assessment

Assessed: 2026-11-08, on commit `4e6ac89` (to be tagged `td2-final` in Étape 3). Paths refer to
that tree. This is the "before" picture and the backlog for phases P1–P6.

## What TD2 delivers

A three-tool pipeline deploying the 3-tier app **NovaShop** on a single-node K3s VM in an
OpenStack DevStack project:

| Tool | What it does | Files |
|---|---|---|
| Terraform | Reads the shared lab resources via data sources (image, flavor, network, keypair); creates a security group (22/80/443 open, 6443 closed), one VM, a floating IP; outputs an Ansible inventory | `terraform/*.tf` |
| cloud-init | Sets the `ubuntu` password with `chpasswd` (keeps the Nova keypair injection working) | `terraform/cloud-init.yaml` |
| Ansible | `k3s-prereq` (static DNS, /etc/hosts, packages), `k3s` (config, install, wait for Ready), `kubeconfig` (fetch and rewrite API address) | `ansible/roles/*` |
| SSH tunnel | Forwards local 6443 to the K3s API so 6443 stays closed | `ansible/tunnel.sh` |
| Helm | Three independent charts: `postgres` (StatefulSet + PVC + init.sql), `backend` (Python API, code in a ConfigMap), `frontend` (nginx + HTML in ConfigMaps, Traefik Ingress) | `helm/*` |

The web page auto-refreshes every 5 s and shows which frontend and backend pod served the
request (proof of load balancing), a visit counter and the item list.

## What is already good

- Clear separation of roles: provisioning (Terraform), configuration (Ansible), deployment (Helm).
- Shared lab resources are only read (data sources), never modified.
- Idempotent playbook (`changed=0` on re-run); K3s API not exposed (tunnel).
- `checksum/*` annotations roll Deployments when ConfigMaps change.
- Careful `.gitignore` (state, tfvars, inventory, kubeconfig) and a README that explains choices.

## Defects and gaps

### Application

| Defect | Where | Fixed in |
|---|---|---|
| Visit counter counts page refreshes, not visits: the page polls `/api/visits` every 5 s and each call inserts a row | `helm/frontend/templates/configmap-html.yaml` (refresh loop), `helm/backend/templates/configmap-code.yaml` (`/api/visits`) | P6 |
| A `GET` endpoint writes to the database (non-idempotent) | `configmap-code.yaml` | P6 |
| If `/api/visits` fails (e.g. missing table on an old DB), the whole page shows "Hors ligne" although `/api/items` works | `configmap-html.yaml` | P6 |
| Stored XSS: item names inserted with `innerHTML` | `configmap-html.yaml` | P6 |
| Error responses leak `str(e)` with `Content-Type: application/json` (not JSON) | `configmap-code.yaml` | P6 |
| Single-threaded `http.server`; a new DB connection per request; no pooling | `configmap-code.yaml` | P6 (FastAPI/Flask + pool, CNPG PgBouncer) |
| `ON CONFLICT DO NOTHING` without a unique constraint has no effect | `helm/postgres/templates/configmap-init.yaml` | P6 |
| `DB_PORT` is set but never read | `helm/backend/templates/deployment.yaml` | P6 |
| Application code in a ConfigMap; `pip install pg8000` (unpinned) at every pod start, requiring Internet | backend chart | P6 (Dockerfile, signed image) |

### Kubernetes / Helm

| Gap | Fixed in |
|---|---|
| No readiness/liveness/startup probes, no `securityContext` (root containers), no PDB, no NetworkPolicy | P5–P6 |
| Plaintext passwords in `values.yaml` and env vars; no Kubernetes Secret | P5 (OpenBao + ESO) |
| Namespace `td2` hard-coded in `db.host` and nginx `proxy_pass` | P6 |
| Three charts installed by hand in a fixed order; boilerplate `Chart.yaml` (`appVersion: "1.16.0"`) | P5–P6 (Argo CD) |
| Hand-written Postgres StatefulSet on `local-path`, no backup | P5 (CloudNativePG + S3) |
| HTTP only although 443 is open | P5 (cert-manager, Gateway API) |

### Infrastructure

| Gap | Fixed in |
|---|---|
| OpenStack provider `~> 1.54` (two majors behind); security group set on the instance instead of the port; unused `asl_subnet` data source | P3–P4 (OpenTofu, provider 3.x) |
| Local Terraform state | P1–P3 (encrypted remote state) |
| SSH password auth (`azerty`) open to `0.0.0.0/0`, `StrictHostKeyChecking=no`, `sshpass` | P1 (keys only, Tailscale, bastion) |
| K3s installed with an unpinned `curl \| sh` | P4 (pinned version, `k3s.orchestration` collection) |
| Paths `~/td2/...` hard-coded in the kubeconfig role and `tunnel.sh` (works only if cloned to `~/td2`) | removed with TD2 |
| DevStack breaks after reboots | P1–P2 (Kolla-Ansible, ADR-0004) |
| No CI, no tests, no monitoring | P0, P5, P7 |
