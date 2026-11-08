---
status: accepted
date: 2026-11-08
decision-makers: dhuy21
---

# Record architecture decisions with MADR

## Context and Problem Statement

akasha is designed through long research and discussion sessions. Decisions and their
rationale must survive beyond any single session, be reviewable, and be versioned.

## Considered Options

* MADR 4.0 Markdown files in `docs/adr/`
* Free-form notes / wiki
* Tool-managed ADRs (log4brains)

## Decision Outcome

Chosen option: "MADR 4.0 Markdown files in `docs/adr/`", because they live next to the
code, go through pull-request review, and need no tooling. log4brains was rejected because
its last release dates from 2024-12 and it appears unmaintained.

### Consequences

* Good, because every design change is traceable to a reviewed decision.
* Good, because future sessions (human or AI) recover context from the repository, not memory.
* Bad, because ADRs must be written and kept up to date as part of each étape.

### Confirmation

Each étape that changes the design adds or supersedes an ADR in the same pull request.
