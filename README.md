# TrustyAI Telco Demos

End-to-end responsible AI demos for the telecom industry built on **Red Hat OpenShift AI** and **TrustyAI**. Each demo covers a distinct AI governance use case — bias detection, drift monitoring, explainability, and guardrails — using realistic 5G and network operations scenarios.

> Validated on: OpenShift 4.20 | RHOAI 2.25 and 3.3

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
│   ├── cluster-admin-setup.sh       # Cluster-admin pre-requisites (run once)
│   ├── patch-kserve.py              # KServe CA bundle patch (run once)
│   └── user-workload-monitoring.yaml
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

All demos share a common cluster-admin setup. Run these once before any demo:

```bash
# 1. Cluster-admin pre-requisites
bash shared/cluster-admin-setup.sh

# 2. KServe CA bundle patch
python3 shared/patch-kserve.py

# 3. Enable user workload monitoring (for Prometheus/Grafana)
oc apply -f shared/user-workload-monitoring.yaml
```

See each demo's `docs/prerequisites.md` for demo-specific setup.

---

## Quick Links

| Resource | Link |
|----------|------|
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
