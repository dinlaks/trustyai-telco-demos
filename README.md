# TrustyAI Telco Demos

End-to-end responsible AI demos for the telecom industry built on **Red Hat OpenShift AI** and **TrustyAI**. Each demo covers a distinct AI governance use case — bias detection, drift monitoring, explainability, and guardrails — using realistic 5G and network operations scenarios.

> Validated on: OpenShift 4.20, 4.21+ | RHOAI 2.25 and 3.3

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
│   ├── cluster-admin-setup.sh       # Cluster-admin RBAC pre-requisites (run once)
│   ├── patch-kserve.py              # KServe CA bundle patch (run once)
│   ├── user-workload-monitoring.yaml
│   ├── preflight.sh                 # Validates all pre-requisites before running the notebook
│   ├── env.sh.example               # Environment variable template (copy to env.sh, gitignored)
│   ├── teardown.sh                  # Removes all demo resources (--confirm required)
│   └── operators/                   # Operator subscriptions — install before any demo
│       ├── README.md                # Ordered install instructions (start here)
│       ├── wave-0/                  # Foundation operators (NFD, cert-manager, OSSM 3, Serverless, GPU)
│       ├── wave-1/                  # RHOAI 3.3 + Authorino
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

All demos share a common cluster setup. Follow these steps in order before running any demo notebook.

### Step 1 — Install Operators (cluster-admin, once per cluster)

Requires a running **OpenShift 4.20 / 4.21+** cluster with `cluster-admin` access.

```bash
# See shared/operators/README.md for full instructions and wait/verify commands
oc apply -f shared/operators/wave-0/00-namespaces.yaml
oc apply -f shared/operators/wave-0/01-nfd-subscription.yaml
oc apply -f shared/operators/wave-0/02-certmanager-subscription.yaml
oc apply -f shared/operators/wave-0/03-servicemesh-subscription.yaml   # OSSM 3.2.2
oc apply -f shared/operators/wave-0/04-serverless-subscription.yaml
oc apply -f shared/operators/wave-0/05-gpu-operator-subscription.yaml  # optional

# Wait for Wave 0 operators to reach Succeeded before continuing

oc apply -f shared/operators/wave-1/01-rhoai-subscription.yaml
oc apply -f shared/operators/wave-1/02-authorino-subscription.yaml

# Wait for RHOAI operator pod to be Running before continuing

oc apply -f shared/operators/post-install/01-datasciencecluster.yaml
oc apply -f shared/operators/post-install/02-user-workload-monitoring.yaml
```

> Full install order, wait commands, and verification steps: [shared/operators/README.md](shared/operators/README.md)

### Step 2 — Cluster-Admin RBAC and KServe Patch (once per cluster)

```bash
# RBAC grants for the demo workbench service account
bash shared/cluster-admin-setup.sh

# KServe CA bundle patch — allows KServe agent to verify TrustyAI TLS
python3 shared/patch-kserve.py
```

### Step 3 — Validate Pre-Requisites

```bash
# Checks operators, DataScienceCluster, RBAC, CA bundle patch, and image reachability
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
| Operator Install Guide | [shared/operators/README.md](shared/operators/README.md) |
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
