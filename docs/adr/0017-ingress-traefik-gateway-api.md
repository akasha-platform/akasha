---
status: accepted
date: 2026-11-09
decision-makers: dhuy21
---

# Ingress: Traefik with Gateway API behind an Octavia L4 load balancer

## Context and Problem Statement

The cluster needs an L7 entry point. ingress-nginx was retired in March 2026 (no further
releases or CVE fixes) and Kubernetes recommends Gateway API. The Octavia OVN provider offers
L4 only.

## Considered Options

* ingress-nginx · Traefik (K3s default) with Gateway API · another Gateway API implementation

## Decision Outcome

Chosen option: "Traefik with Gateway API". K3s's bundled Traefik is disabled at install and
reinstalled through Argo CD so every add-on is GitOps-managed; Traefik's
`providers.kubernetesGateway` is enabled; one Octavia (OVN provider) L4 load balancer fronts
Traefik, which terminates TLS with certificates from cert-manager (ADR-0019).

### Consequences

* Good, because it follows the upstream migration path and needs no amphora VMs.
* Bad, because Traefik's latest published Gateway API conformance report found was for v1.3
  (to re-check).
