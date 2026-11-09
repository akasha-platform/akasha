# NovaShop

The 3-tier demo application (frontend, API, PostgreSQL), rebuilt in phase P6 as signed
container images deployed by Argo CD. The TD2 version lives at tag `td2-final`; the defects
to fix are listed in [research/00](../../docs/research/00-td2-baseline-assessment.md).

Planned structure:

```
src/          application code and tests
Dockerfile    image build (BuildKit, non-root)
chart/        Helm chart consumed by akasha-gitops
```
