# TrustyAI Telco Demos

End-to-end responsible AI demos for the telecom industry built on **Red Hat OpenShift AI** and **TrustyAI**. Each demo covers a distinct AI governance use case — bias detection, drift monitoring, explainability, and guardrails — using realistic 5G and network operations scenarios.

> **Validated on:** OpenShift 4.18+ | RHOAI **2.25** (setup scripts target 2.25 only)
> A notebook for RHOAI 3.3 is included for reference but the automated setup (`deploy-prereqs.sh`) is not validated on RHOAI 3.x.

---

## Use Cases

| Demo | Use Case | Status |
|------|----------|--------|
| [bias-detection](bias-detection/) | Detect and remediate geographic bias in 5G network slice allocation | Available |
| drift-monitoring | Monitor model drift in real-time network traffic classification | Coming soon |
| explainability | Explain individual AI decisions for network fault prediction | Coming soon |
| guardrails | Enforce policy guardrails on LLM-assisted network operations | Coming soon |

---

## The TrustyAI Telco Story

A modern telecom operator uses AI at every layer of the network — from automated slice allocation to fault prediction to customer experience optimization. Each of these AI systems introduces risk:

- **Bias** — does the model treat all customers and regions equally?
- **Drift** — is the model's behavior changing as network conditions evolve?
- **Opacity** — can engineers explain why the model made a specific decision?
- **Guardrails** — are LLM-assisted operations staying within safe policy boundaries?

TrustyAI, integrated natively into Red Hat OpenShift AI, provides the observability and governance layer that answers all four questions — in production, in real time, without changing model code.

These demos walk through each capability end-to-end in realistic telco scenarios.

---

## Repository Structure

```
trustyai-telco-demos/
├── README.md                        # This file
├── .gitignore
│
├── shared/                          # Common setup scripts (used by all demos)
│   ├── deploy-prereqs.sh            # ★ Single script — installs everything end-to-end (start here)
│   ├── cluster-admin-setup.sh       # Cluster-admin RBAC pre-requisites (called by deploy-prereqs.sh)
│   ├── patch-kserve.py              # KServe CA bundle patch (called by deploy-prereqs.sh)
│   ├── user-workload-monitoring.yaml
│   ├── preflight.sh                 # Validates all pre-requisites before running the notebook
│   ├── env.sh.example               # Environment variable template (copy to env.sh, gitignored)
│   ├── teardown.sh                  # Removes all demo resources (--confirm required)
│   └── operators/                   # Operator subscriptions — install before any demo
│       ├── README.md                # Ordered install instructions (start here)
│       ├── wave-0/                  # Foundation operators (NFD, cert-manager, OSSM 2.x, Serverless, GPU)
│       ├── wave-1/                  # RHOAI 2.25 + Authorino
│       └── post-install/            # DataScienceCluster CR + user workload monitoring
│
├── bias-detection/                  # Demo 1 — Geographic bias in 5G slice allocation
│   ├── README.md
│   ├── notebooks/
│   ├── docs/
│   ├── setup/
│   └── assets/
│
├── drift-monitoring/                # Demo 2 — Coming soon
├── explainability/                  # Demo 3 — Coming soon
└── guardrails/                      # Demo 4 — Coming soon
```

---

## Shared Setup

All demos share a common cluster setup. Run the steps below **once per cluster** as `cluster-admin` before opening any demo notebook.

Requires a running **OpenShift 4.18+** cluster and `oc` CLI logged in as `cluster-admin`.

> ⚠️ **Version note:** `deploy-prereqs.sh` and all operator manifests target **RHOAI 2.25** with OSSM 2.x. They are not validated for RHOAI 3.x.

### Option A — Single script (recommended)

`deploy-prereqs.sh` orchestrates the full setup end-to-end: operator installation, RHOAI activation, workbench creation, RBAC grants, KServe CA patch, and final validation.

```bash
bash shared/deploy-prereqs.sh
```

What it does:

| Step | Action |
|------|--------|
| 1–2  | Wave 0 operators — NFD, cert-manager, OSSM 2.x, Serverless (waits for `Succeeded`) |
| 3–4  | Wave 1 operators — RHOAI 2.25 + Authorino (waits for `Succeeded`) |
| 5–6  | DataScienceCluster CR + user workload monitoring (waits for `Ready`) |
| 7–9  | Creates `rhoai-demo` project, waits for notebook webhook, creates `telco-wb` workbench |
| 10   | Waits for workbench pod `2/2 Running` |
| 11   | RBAC grants — `cluster-admin-setup.sh` |
| 12   | Preflight validation — `preflight.sh` |
| 13   | KServe CA bundle patch — `patch-kserve.py` (marks `inferenceservice-config` unmanaged + adds caBundle) |

> **Note:** All `oc apply` calls are idempotent. Safe to re-run if the cluster already has operators installed (e.g. a Demo Platform environment with RHOAI pre-provisioned).

### Option B — Manual step-by-step

For environments where you need more control over each wave, apply the manifests individually and verify health between waves. See [shared/operators/README.md](shared/operators/README.md) for the full manual sequence.

### Validate Pre-Requisites

To check the cluster state at any point without re-running setup:

```bash
bash shared/preflight.sh
```

### Teardown (after demo)

```bash
# Removes demo namespace, Grafana dashboard, and RBAC grants — leaves RHOAI intact
bash shared/teardown.sh --confirm
```

See each demo's `docs/prerequisites.md` for demo-specific setup.

---

## Quick Links

| Resource | Link |
|----------|------|
| Full Pre-Req Setup Script | [shared/deploy-prereqs.sh](shared/deploy-prereqs.sh) |
| Manual Operator Install Guide | [shared/operators/README.md](shared/operators/README.md) |
| Bias Detection Demo | [bias-detection/README.md](bias-detection/README.md) |
| Business Use Case | [bias-detection/docs/business-use-case.md](bias-detection/docs/business-use-case.md) |
| TrustyAI Value Proposition | [bias-detection/docs/trustyai-value-proposition.md](bias-detection/docs/trustyai-value-proposition.md) |
| Architecture | [bias-detection/docs/architecture.md](bias-detection/docs/architecture.md) |
| Demo Walkthrough (Presenter Guide) | [bias-detection/docs/demo-walkthrough.md](bias-detection/docs/demo-walkthrough.md) |
| Prerequisites | [bias-detection/docs/prerequisites.md](bias-detection/docs/prerequisites.md) |

---

## References

- [TrustyAI Documentation](https://trustyai.org/docs/main/main)
- [Red Hat OpenShift AI Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)
- [EU AI Act](https://artificialintelligenceact.eu/)
