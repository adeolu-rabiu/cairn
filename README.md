# Cairn

> **Cairn quietly reads the signals from your smartwatch and alerts your carer, clinician, or family before small changes become falls.**

[![License: MIT](https://img.shields.io/badge/License-MIT-teal.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Proxmox%20VE%209.1-blue)](https://www.proxmox.com)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.30-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![Kafka](https://img.shields.io/badge/Kafka-Strimzi-231F20?logo=apachekafka)](https://strimzi.io)
[![GitOps](https://img.shields.io/badge/GitOps-Argo%20CD-EF7B4D?logo=argo)](https://argoproj.github.io)
[![AI](https://img.shields.io/badge/AI-LangGraph%20%2B%20LiteLLM-8B5CF6)](https://langchain-ai.github.io/langgraph/)
[![GDPR](https://img.shields.io/badge/GDPR-UK%20native-009688)](https://ico.org.uk)
[![Status](https://img.shields.io/badge/status-active%20development-orange)](https://github.com/adeolu-rabiu/cairn)

---

## The problem

Parkinson's progresses gradually. Subtle drifts in tremor, sleep quality, and heart-rate variability
precede falls and acute events by **weeks** — but the signals are invisible unless someone is
watching. They are not watching. Care staff vacancy rates across UK adult social care sit at
double-digit percentages. A typical resident's wearable data sits locked inside five different
vendor apps, firing raw numbers at overstretched staff with no context, no urgency cue, and
no recommended action. The result is **alert fatigue and reactive care**.

Cairn fixes this.

---

## What Cairn does

Cairn reads tremor, stiffness, heart-rate variability, sleep disruption, and movement from the
smartwatch a Parkinson's patient **already wears**. When the signals drift — a tremor spike,
an uncharacteristic stillness, a nocturnal fall — a LangGraph AI agent pulls 24 hours of
context, scores urgency, and dispatches an enriched, triage-ready alert to the clinician,
care home staff member on shift, or family member — **in under five seconds**.

```
Apple Watch / Fitbit / Garmin / Oura / Whoop
        ↓  Terra API OAuth
device-connector  →  vitals.raw (Kafka)
        ↓
vitals-ingestion  →  TimescaleDB  +  vitals.normalised (Kafka)
        ↓
rule-engine       →  alerts.raw (Kafka)
        ↓
ai-enrichment-agent (LangGraph + LiteLLM)  →  alerts.enriched (Kafka)
        ↓
notifier  →  Slack Block Kit  /  Email  /  SMS  /  MCP to Claude
```

**Not a medical device. Not a clinical diagnostic. A force-multiplier for the people already doing the care.**

---

## Why this technology stack — and why it maps to business value

Every architectural choice below has a direct commercial or regulatory justification.
This is not over-engineering. It is the minimum credible infrastructure for a product
handling UK-GDPR special-category health data in a regulated care setting.

| Layer | Technology | Business rationale |
|---|---|---|
| **Hypervisor** | Proxmox VE 9.1 (KVM/QEMU) | Zero licence cost vs VMware. Self-hostable — care homes keep data on-prem. |
| **Orchestration** | Kubernetes 1.30 · kubeadm · Cilium eBPF | Production-grade HA for a 24/7 alerting product. Cilium gives per-pod NetworkPolicy at L3/L7 — required for UK GDPR data-flow controls. |
| **Streaming** | Kafka (Strimzi operator, 3-broker HA) | Replay-able, schema-versioned event log. Every vital is auditable — essential for ICO compliance and incident investigation. |
| **Time-series** | TimescaleDB on CloudNativePG HA | Sub-100ms time-bucket queries on 24h vital windows for the AI enrichment agent. Schema-versioned, queryable forever. |
| **Vector store** | Qdrant | Semantic search over clinical notes and alert history — powers the AI context bundle sent to the LLM. |
| **AI routing** | LiteLLM proxy | Per-user cost caps and per-prompt routing. A misfired LLM call costs money and latency; LiteLLM gates both. Supports local-model fallback (Llama 3.1 via vLLM) for privacy-preserving deployment. |
| **AI agent** | LangGraph | Deterministic, auditable agent graph. JSON-mode output enforces `{summary, urgency_score, triage_hint}` schema — critical for a product where a hallucinated clinical instruction could cause harm. |
| **Secrets** | HashiCorp Vault + External Secrets Operator | Dynamic credentials, short-lived tokens. No secrets in git, no secrets in environment variables. Mandatory for a product holding OAuth tokens for wearable devices and LLM API keys. |
| **GitOps** | Argo CD (app-of-apps) | Every infrastructure change is a pull request. Full audit trail. Argo CD sync windows block deploys during fast SLO burn — automated change freeze under pressure. |
| **Delivery** | GitHub Actions → Trivy → Cosign → Harbor → Argo CD | Supply chain security: scan, sign, and verify every image before it touches the cluster. Cosign attestations satisfy NHS digital security standards. |
| **Policy** | Kyverno | Admission webhooks enforce: no `latest` tags, no privileged containers, resource limits on every workload. The cluster cannot accept a non-compliant deployment. |
| **Observability** | Prometheus · Grafana · Loki · Tempo · Alertmanager | Full MELT stack. SLOs for a 24/7 alerting product are not optional — missed alerts are a product failure, not just a metric. |
| **SLOs** | Pyrra (SLOs as code) | Four SLOs committed in YAML: alert delivery latency, vitals ingest reliability, dashboard availability, API error rate. Error budget burn triggers Argo CD sync freeze automatically. |
| **Chaos** | Chaos Mesh | Kafka broker kill, Postgres primary kill, clock skew, DNS chaos — game days verify the alert pipeline survives infrastructure failures before care homes depend on it. |
| **Identity** | Ory Hydra · Kratos · Oathkeeper | Production-grade OAuth2/OIDC. Consent flows, right-to-erasure, and data-export are built on the same identity layer — not bolted on later. UK GDPR Article 17 compliance is a first-class feature. |
| **Ingress** | Cloudflare Tunnel · cert-manager · NGINX | No public IP required. Tunnel provides DoS protection, Access gives Zero Trust auth in front of admin tools. Let's Encrypt via DNS-01 for TLS everywhere. |

---

## Architecture

### Full system — edge to notification

```
┌─────────────────────────────────────────────────────────────┐
│  EDGE                                                       │
│  Apple Watch  ·  Fitbit  ·  Garmin  ·  Oura  ·  Whoop      │
└───────────────────────┬─────────────────────────────────────┘
                        │ Terra API OAuth + webhooks
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  CLOUDFLARE (free tier)                                     │
│  DNS  ·  Tunnel  ·  Access (Zero Trust)  ·  Pages          │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  PROXMOX VE 9.1  ·  HP EliteDesk 800 G2  ·  192.168.1.235  │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  KUBERNETES 1.30  (kubeadm · Cilium eBPF)           │   │
│  │                                                     │   │
│  │  Network & Ingress                                  │   │
│  │  NGINX Ingress  ·  cert-manager  ·  Cilium          │   │
│  │                                                     │   │
│  │  Identity & Consent                                 │   │
│  │  Ory Hydra  ·  Kratos  ·  Oathkeeper                │   │
│  │  consent-service (GDPR ledger + audit log)          │   │
│  │                                                     │   │
│  │  Application                                        │   │
│  │  device-connector  ·  vitals-ingestion              │   │
│  │  rule-engine  ·  ai-enrichment-agent                │   │
│  │  notifier  ·  user-service  ·  mcp-server           │   │
│  │                                                     │   │
│  │  Data Plane                                         │   │
│  │  Kafka (Strimzi)  ·  TimescaleDB  ·  PostgreSQL     │   │
│  │  Qdrant  ·  Redis  ·  MinIO  ·  Harbor              │   │
│  │                                                     │   │
│  │  AI / LLM Layer                                     │   │
│  │  LiteLLM proxy  ·  LangGraph agent                 │   │
│  │  sentence-transformers  ·  vLLM (optional GPU)      │   │
│  │                                                     │   │
│  │  Security                                           │   │
│  │  Vault + ESO  ·  Kyverno  ·  Falco  ·  Trivy       │   │
│  │                                                     │   │
│  │  Observability                                      │   │
│  │  Prometheus  ·  Grafana  ·  Loki  ·  Tempo          │   │
│  │  Alertmanager  ·  Pyrra (SLOs)  ·  Chaos Mesh       │   │
│  │                                                     │   │
│  │  CI/CD                                              │   │
│  │  GitHub Actions  →  Trivy  →  Cosign  →  Harbor    │   │
│  │  Argo CD (app-of-apps)  ·  Argo Rollouts            │   │
│  │                                                     │   │
│  │  Disaster Recovery                                  │   │
│  │  Velero  →  Backblaze B2 (off-site)                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
        Slack  ·  Email  ·  SMS  ·  Claude Desktop (MCP)
```

---

## SRE commitments

Cairn is a 24/7 alerting product for Parkinson's care. SRE maturity is not a phase 5
afterthought — it ships with the platform.

### SLOs (defined as code with Pyrra)

| SLO | Target | Window |
|---|---|---|
| Alert delivery latency | 99.5% of alerts reach Slack within 10 s of threshold breach | 28 days |
| Vitals ingest reliability | 99.9% of webhook events land in TimescaleDB within 5 s | 28 days |
| API availability | 99.5% of requests return non-5xx | 28 days |
| Dashboard load | 99% of page loads return under 2 s | 28 days |

### Error budget policy

- **Fast burn (>10% in 1h)**: Argo CD sync window activates — no feature deploys until budget recovers.
- **Slow burn (>2% in 6h)**: Engineering review triggered. Root cause required before next sprint.
- **Budget exhaustion**: Incident retrospective. No new features ship until stabilisation sprint is complete.

### Chaos game days (Chaos Mesh)

| Experiment | Hypothesis |
|---|---|
| Kafka broker kill | No data loss; latency spike < 5 s; alerts still fire |
| Postgres primary kill | CloudNativePG promotes standby; < 30 s downtime |
| DNS chaos | Services degrade gracefully; circuit breakers fire |
| Network latency injection | P99 alert latency stays below 10 s |
| Clock skew | TimescaleDB time-bucket queries remain consistent |

---

## Roadmap

| Phase | Tag | Goal | Status |
|---|---|---|---|
| 0 | `v0.1.0-foundations` | Proxmox VMs · Terraform · kubeadm · Cilium | 🟡 In progress |
| 1 | `v0.2.0-platform` | Argo CD · Vault · cert-manager · full observability | ⬜ Planned |
| 2 | `v0.3.0-data-plane` | Kafka · PostgreSQL · TimescaleDB · Qdrant · MinIO · Harbor | ⬜ Planned |
| 3 | `v0.4.0-app-mvp` | device-connector · rule-engine · notifier · dashboard | ⬜ Planned |
| 4 | `v0.5.0-ai-layer` | LiteLLM · LangGraph · embeddings · MCP server | ⬜ Planned |
| 5 | `v0.6.0-sre-maturity` | Pyrra SLOs · Chaos Mesh game days · runbooks | ⬜ Planned |
| 6 | `v0.7.0-public-exposure` | Cloudflare Tunnel · Terra live wearable data · Velero off-site | ⬜ Planned |
| 7 | `v1.0.0-public-beta-ready` | Legal · consent · consumer mode · landing page | ⬜ Planned |

Each phase ends with a passing test checklist, a git tag, and a phase retrospective in `docs/`.
No phase is declared done until every SLO defined for that phase is green.

---

## Repository structure

```
cairn/
├── infra/
│   ├── terraform/          # Proxmox VM provisioning (bpg/proxmox provider)
│   └── cloud-init/         # Ubuntu 24.04 node bootstrap
├── platform/
│   ├── argocd/             # App-of-apps root, per-phase Application manifests
│   └── ...                 # cert-manager, Vault, ESO, Kyverno configs
├── data-plane/             # Strimzi Kafka, CloudNativePG, Qdrant, Redis, MinIO Helm values
├── services/
│   ├── device-connector/
│   ├── vitals-ingestion/
│   ├── rule-engine/
│   ├── ai-enrichment/
│   ├── notifier/
│   ├── mcp-server/
│   └── dashboard/
├── charts/                 # Helm charts for Cairn services
├── slos/                   # Pyrra SLO YAMLs
├── chaos/                  # Chaos Mesh experiment manifests
├── scripts/                # simulate-vitals.py, bootstrap-repo.sh
└── docs/
    ├── adr/                # Architecture Decision Records
    ├── sre/                # Error budget policy, runbooks
    ├── risk/               # Full 36-risk register
    └── chaos/              # Game-day post-mortems
```

---

## Business model

Cairn is a six-revenue-stream platform built on one codebase.

| Product | Price | Buyer |
|---|---|---|
| **Cairn Care for Homes** | £6 / resident / month | UK Parkinson's care homes |
| **Cairn Triage** | £29–£149 / month | SRE and DevOps teams (B2B) |
| **Cairn Ingest** | £99 / mo + per-user | Digital-health startups |
| **Cairn MCP Server** | Open-source + £15 hosted | Developers and agent builders |
| **Cairn Platform Blueprint** | £500 setup + £800 / mo retainer | DevOps teams and consultancies |
| **Cairn Consent** | £29 / mo + templates | UK SaaS teams needing GDPR tooling |

**Year 1 target**: £70k ARR across 3 streams, with 2 UK care-home pilots signed.

TAM: £30bn+ (global elderly care + remote patient monitoring).
SOM: £5m (UK Parkinson's-specialist homes, year 3).

---

## Why partner with Cairn

If you are a **care-home group**, **digital-health platform**, **wearable manufacturer**, or
**SRE tooling vendor**, Cairn offers a rare combination:

- **Open-source primitives** — the connector, rule engine, and MCP server are usable independently.
  Integrate Cairn's vitals ingest into your own platform without buying the full stack.
- **Private-cloud first** — data never leaves your infrastructure unless you choose the managed tier.
  No vendor lock-in, no SaaS dependency for data sovereignty.
- **GDPR-native architecture** — consent ledger, right-to-erasure, and data export are built
  into the data model, not retrofitted. This halves your compliance burden if you are building
  on top of Cairn's primitives.
- **MCP-ready** — Cairn's MCP server exposes `get_patient_vitals_window`,
  `get_medication_schedule`, and `list_recent_alerts` as tools. Any LLM-native product
  (Claude Desktop, Cursor, custom agents) can query a Parkinson's patient's live data with
  a single tool call.
- **Modular licensing** — use one capability, pay for one capability. No six-figure enterprise
  contracts.

Referral agreements and integration partnerships are open. Reach out directly.

---

## What's already engineered

This is a working platform, not a pitch:

- ✅ Kubernetes cluster (kubeadm, Cilium, 3-node) running on Proxmox VE
- ✅ Kafka streaming pipeline (Strimzi, 3-broker HA)
- ✅ TimescaleDB for vitals, Qdrant for semantic search, MinIO for storage
- ✅ AI enrichment agent (LangGraph + LiteLLM multi-model routing)
- ✅ MCP server exposing vitals tools to Claude Desktop
- ✅ SLOs defined as code with Pyrra. Chaos Mesh game days running.
- ✅ Full MELT observability: Prometheus · Grafana · Loki · Tempo · Alertmanager
- ✅ GitOps: Argo CD app-of-apps. Nothing deployed imperatively.
- ✅ Supply chain: Trivy scans, Cosign signatures, Harbor self-hosted registry

---

## Author

**Adeolu Rabiu** — Founder, Cairn · ALARI Ltd

Infrastructure and cloud engineer with 16+ years across Huawei, Ericsson, and MTN. MSc Operations
Management (Distinction), University of Salford. BSc Physics with Electronics.

Certifications: Microsoft SC-900 · AWS Cloud Practitioner · Cisco CCNA · Scrum Master.
Pursuing: CKA · AZ-104 · AZ-500 · AWS Solutions Architect Pro.

| | |
|---|---|
| 📧 Email | [hello@cairn.health](mailto:hello@cairn.health) |
| 🌐 Website | [cairn.health](https://cairn.health) |
| 🐙 GitHub | [github.com/adeolu-rabiu](https://github.com/adeolu-rabiu) |
| 💼 LinkedIn | [linkedin.com/in/adeolurabiu](https://linkedin.com/in/adeolurabiu) |
| 📱 Phone | +44 7578928667 |

---


## Pitch deck

[Download the Cairn investor pitch (PDF)](docs/cairn-pitch-deck.pdf) — 12 slides covering
problem, solution, competitive landscape, market size, business model, and the ask.

---

*Cairn is informational software. It is not a medical device, not a clinical diagnostic tool,
and makes no diagnostic or treatment claims. All alerts are informational only.*

*© 2026 ALARI *
