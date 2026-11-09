---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Observability stack

## Considered Options

* kube-prometheus-stack + Loki + Grafana Alloy
* VictoriaMetrics + VictoriaLogs (lighter)

## Decision Outcome

Chosen option: "kube-prometheus-stack + Loki (monolithic) + Alloy + Grafana", the most common
stack in the industry. Tuned for a small cluster: short retention (5–7 days), dropped unused
series, Loki monolithic with caches disabled (the chart default allocates 8 GB to the chunks
cache). Promtail is end-of-life (2026-03-02), hence Alloy. Kolla's Prometheus is **disabled by
default**; it is enabled explicitly (`enable_prometheus: "yes"`, 7-day retention via
`prometheus_cmdline_extras`, ≈ +0.3–0.5 GB on the controller) to keep OpenStack metrics on the
controller; the host is scraped too, with a second scraper or a
dead-man's-switch alert so the monitor does not live only inside the failure domain it watches.

### Consequences

* Good, because skills and dashboards transfer directly to production teams.
* Bad, because it costs ~2–2.5 GB of the K8s guest RAM.
