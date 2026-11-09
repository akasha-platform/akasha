---
status: accepted
date: 2026-11-09
decision-makers: dhuy21
---

# Policy engine: Kyverno with Pod Security Admission

## Context and Problem Statement

The cluster needs admission policies: Pod Security Standards, image signature verification,
and a guard for the privileged BuildKit namespace.

## Considered Options

* Native ValidatingAdmissionPolicy only (no extra memory)
* Kyverno · OPA Gatekeeper

## Decision Outcome

Chosen option (confirmed explicitly by the owner on 2026-11-09): "Kyverno" (CNCF graduated) together with Pod Security Admission (`restricted`
by default, `privileged` only for the build namespace). Kyverno is needed for image signature
and attestation verification (ImageValidatingPolicy), which native ValidatingAdmissionPolicy
cannot do. New policies use the CEL-based ValidatingPolicy / ImageValidatingPolicy kinds,
because ClusterPolicy is deprecated since Kyverno 1.19.

### Consequences

* Good, because unsigned images and unsafe pods are rejected at admission.
* Bad, because it costs ~0.3–0.45 GB; native ValidatingAdmissionPolicy remains the fallback if
  RAM runs out (open-questions B1).
