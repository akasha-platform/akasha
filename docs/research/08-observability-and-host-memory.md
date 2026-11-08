# 08 — Observability, data services and host memory

Researched: 2026-11-08. Re-check versions. All memory gains below are **ESTIMATED**; measure them before relying on any of them.

## Metrics, logs, traces

- **kube-prometheus-stack** is still the default choice (chart 93.1.0).
  - Prometheus alone uses about 0.5–1.5 GiB on homelab clusters. Use short retention and drop unused scrape jobs.
  - **VERIFIED** (chart) / **ESTIMATED** (RAM): https://github.com/prometheus-community/helm-charts/releases , https://discuss.prometheus.io/t/reducing-memory-usage-in-homelab-deployment/3285
- **victoria-metrics-k8s-stack** is the lighter alternative (about 0.5 GiB). It converts ServiceMonitor and PrometheusRule objects. **VERIFIED**: https://docs.victoriametrics.com/helm/victoria-metrics-k8s-stack/
  - Not chosen: the project prefers the market-standard Prometheus stack.
- **Promtail reached EOL on 2026-03-02.** Its replacement is **Grafana Alloy** (v1.21.3). **VERIFIED**: https://grafana.com/docs/loki/latest/send-data/promtail/ , https://github.com/grafana/alloy/releases
- **Loki:**
  - Latest stable is v3.7.9; v4.0.0-rc.3 is out. **VERIFIED**: https://github.com/grafana/loki/releases
  - **Loki 4.0 removes Simple Scalable mode.** Use Monolithic. **VERIFIED**: https://grafana.com/docs/loki/latest/get-started/deployment-modes/
  - The Helm chart is community-maintained since 2026-03-16. `SingleBinary` was renamed `Monolithic`, and the bundled MinIO was deprecated. **VERIFIED**: https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/
  - The default `chunksCache.allocatedMemory` is **8192 MB**, so disable the caches in the lab. **VERIFIED**: https://raw.githubusercontent.com/grafana/loki/main/production/helm/loki/values.yaml
- **Tracing:**
  - **Tempo 3.0** runs in-process in monolithic mode. **VERIFIED**: https://grafana.com/docs/tempo/latest/release-notes/v3-0/
  - OpenTelemetry has **no instrumentation for Python `http.server`**; Flask, FastAPI and psycopg have one. That is one reason to move the NovaShop API to FastAPI. **VERIFIED**: https://github.com/open-telemetry/opentelemetry-python-contrib/tree/main/instrumentation
- **SLOs:** Sloth v0.16.0 and Pyrra v0.10.0 generate multi-window burn-rate rules. **VERIFIED**: https://github.com/slok/sloth/releases , https://github.com/pyrra-dev/pyrra

## Data services

- **CloudNativePG v1.30.1.** It is a CNCF Sandbox project. **VERIFIED**: https://github.com/cloudnative-pg/cloudnative-pg/releases
  - **In-tree `barmanObjectStore` is removed in 1.31.** Use the **Barman Cloud Plugin** (v0.15.1) instead. **VERIFIED**: https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/
  - The `Pooler` CRD (PgBouncer) fixes the old app's one-connection-per-request problem. **INFERRED**
- **Velero** joined the CNCF Sandbox (2026-03-17), uses Kopia and has dropped Restic. **VERIFIED**: https://www.infoq.com/news/2026/05/broadcom-velero-cncf/

## Ingress and TLS

- **ingress-nginx was retired in March 2026.** The recommended path is **Gateway API**. **VERIFIED**: https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
- **Gateway API** is at v1.7.0. **VERIFIED**: https://github.com/kubernetes-sigs/gateway-api/releases
- **Traefik v3**, bundled with K3s, supports Gateway API. **VERIFIED**: https://doc.traefik.io/traefik/v3.8/reference/routing-configuration/kubernetes/gateway-api/
- **cert-manager** is at v1.21.3. Lab certificates come from the internal CA via the Vault issuer (see [07](07-trust-and-data.md)). **VERIFIED**: https://github.com/cert-manager/cert-manager/releases

## Reliability basics applied to every workload

**INFERRED**: standard practice.
- **Probes:** readiness checks dependencies with a short timeout; liveness is cheap and has no DB check; add a startup probe for slow boots.
- **Resources:** requests on every container; memory limit equal to request.
- **Disruption and rollout:** PDB `minAvailable: 1` for 2-replica tiers; RollingUpdate with `maxUnavailable: 0`.
- **Shutdown:** handle SIGTERM gracefully and add a `preStop` sleep.
- **Security context:** `runAsNonRoot`, read-only root filesystem.
- **Logs:** structured JSON logs that carry a trace ID.

## Host memory headroom

**Why this matters.** The host is about **100% committed**:
- host ~3 GB
- OPNsense 3 GB
- bastion 1 GB
- core 0.75 GB
- ctl01 8 GB
- cmp01 and cmp02 ~7.6 GB each

That totals about 31 GB. Production keeps 20–30% headroom. The techniques below create a **safety buffer, not capacity**. Size the host as if they were off.

| Technique | Expected gain | Key facts | Plan |
|---|---|---|---|
| **KSM on the host** | 1.5–4 GB | Kernel 6.12 has `smart_scan` (default on, about 25% less CPU) and the advisor (`advisor_mode=scan-time`); do not use the 2015 `ksmtuned` script. KSM on L0 also merges the nested L2 guests' pages. credativ measured −48% on idle identical VMs (best case). | Enable on the host only; `use_zero_pages=1`; `advisor_max_cpu=25`; optionally `nosharepages` for ctl01. CVE-2015-2877 is accepted, since there is a single tenant. |
| **Free page reporting** | 0.5–3 GB, fluctuating | `<memballoon model='virtio' freePageReporting='on' autodeflate='on'/>` (libvirt ≥ 6.9). The provider 0.9.9 exposes `devices.mem_balloon.free_page_reporting`. **Nova 2025.2+ enables it for its guests.** FreeBSD/OPNsense does not support it. Page cache limits the gain. | Linux VMs except ctl01; optional `memory.reclaim` timer or `damon_reclaim` inside guests (not on ctl01 or etcd nodes) |
| **zswap (not zram)** | 2–5 GB of compressed cold-memory buffer | zram at top priority suffers LRU inversion; "if in doubt, zswap". On Debian, add zstd to the initramfs or it silently falls back to LZO. | `zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc zswap.max_pool_percent=20`, `vm.swappiness=80`, in front of the existing NVMe swap |
| **Monitoring** | — | node-exporter: PSI, `oom_kill`, `pswpin`; the ksmd collector is off by default (`--collector.ksmd`); per-VM memory via the inovex libvirt exporter. | Alerts below, plus a second scraper or a dead-man's switch, because Prometheus on ctl01 lives inside the failure domain it watches |

**Sources for the table:**
- KSM — **VERIFIED**: https://docs.kernel.org/admin-guide/mm/ksm.html , https://kernelnewbies.org/Linux_6.8 , https://www.credativ.de/en/blog/credativ-inside/evaluate-ksm-and-ballooning-features-in-proxmox-ve/ , https://lwn.net/Articles/953141 , https://access.redhat.com/security/cve/CVE-2015-2877
- Free page reporting — **VERIFIED**: https://libvirt.org/formatdomain.html , https://docs.openstack.org/releasenotes/nova/2025.2.html , https://github.com/freebsd/freebsd-src/blob/main/sys/dev/virtio/balloon/virtio_balloon.c , https://docs.kernel.org/admin-guide/mm/damon/reclaim.html
- zswap vs zram — **VERIFIED**: https://chrisdown.name/2026/03/24/zswap-vs-zram-when-to-use-what.html , https://docs.kernel.org/admin-guide/sysctl/vm.html , https://lists.debian.org/debian-user/2025/09/msg00547.html
- Monitoring — **VERIFIED**: https://github.com/inovex/prometheus-libvirt-exporter , https://docs.openstack.org/kolla-ansible/2026.1/reference/logging-and-monitoring/prometheus-guide.html

**Alert rules** (thresholds **ESTIMATED**):

| Condition | Duration | Severity |
|---|---|---|
| `MemAvailable/MemTotal < 0.10` | 5 min | warning |
| `MemAvailable/MemTotal < 0.05` | — | critical |
| PSI memory "some" rate > 0.10 | — | warning |
| PSI memory "full" rate > 0.02 | — | critical |
| `rate(pswpin) > 500` | 10 min | — |
| `increase(oom_kill) > 0` | — | — |
| KSM profit drop > 2 GB | 30 min | — |

**OOM protection**
- **Do not enable systemd-oomd or earlyoom for VMs.** They kill whole VMs. **VERIFIED**: https://packages.debian.org/trixie/systemd-oomd , https://github.com/rfjakob/earlyoom
- Protect VMs from host processes with `MemoryLow=` on `machine.slice`.
- Set per-VM `oom_score_adj` through a libvirt qemu hook, so that if the kernel must kill a VM it picks a compute rather than ctl01 or core.
- libvirt `soft_limit` maps to `memory.high` (a throttle), and libvirt advises against `hard_limit`. **VERIFIED**: https://libvirt.org/formatdomain.html

**Measure after deployment**
- KSM `general_profit`, and ksmd CPU.
- zswap `Zswap`/`Zswapped` in `/proc/meminfo`.
- Per-VM RSS.
- PSI.
- Galera commit latency, RabbitMQ publish latency, and etcd `wal_fsync` p99, with KSM on vs off (`run=2` to unmerge).
