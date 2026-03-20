# TrustyAI Value Proposition

## What Is TrustyAI?

TrustyAI is Red Hat's open-source responsible AI toolkit, integrated natively into Red Hat OpenShift AI. It provides production-grade AI observability — monitoring every inference decision a deployed model makes, computing fairness metrics automatically, and integrating with the OpenShift monitoring stack (Prometheus, Grafana, AlertManager) for real-time bias detection and alerting.

TrustyAI is not a governance checklist tool or a post-training audit framework. It is a **live production monitoring system** that operates alongside deployed models with zero changes to model code or inference logic.

---

## The Core Value: Fairness Observability as Infrastructure

Traditional AI monitoring answers: *"Is the model working?"*
TrustyAI answers: *"Is the model working fairly?"*

| Capability | Traditional Monitoring | TrustyAI |
|-----------|----------------------|---------|
| Uptime and latency | Yes | Yes |
| Error rate | Yes | Yes |
| Prediction accuracy | Partial | Yes |
| Group-level fairness metrics | No | Yes |
| Real-time bias alerting | No | Yes |
| Regulatory audit trail | No | Yes |
| Automated remediation trigger | No | Yes |

---

## Key Capabilities Demonstrated in This Demo

### 1. Automatic Inference Logging

TrustyAI deploys as a sidecar alongside the KServe InferenceService. Every inference request — the input features and the model's predicted output — is captured automatically. No changes to the model, the serving runtime, or the calling application are required.

```
Customer Request → KServe Agent → OVMS Model Server
                       |
                       └──→ TrustyAI (automatic copy of every input/output)
```

**Business value:** Complete audit trail of every AI decision. Regulatory evidence that monitoring was in place.

### 2. Statistical Parity Difference (SPD)

SPD measures the gap in favorable outcome rates between a privileged group and an unprivileged group:

```
SPD = P(Tier-2 | Urban) − P(Tier-2 | Rural)

SPD = 0.0   →  perfectly equal treatment
SPD = +0.25 →  Urban customers get Premium 25% more often than Rural
```

| SPD Value | Interpretation |
|-----------|---------------|
| −0.10 to +0.10 | Fair — within acceptable threshold |
| +0.10 to +0.15 | Warning — approaching alert threshold |
| > +0.15 or < −0.15 | Alert — regulatory threshold exceeded |

### 3. Disparate Impact Ratio (DIR)

DIR measures the ratio of favorable outcomes between groups — derived from the "4/5ths rule" established in U.S. employment law and adopted in AI fairness standards:

```
DIR = P(Tier-2 | Rural) / P(Tier-2 | Urban)

DIR = 1.0  →  equal treatment
DIR = 0.70 →  Rural customers are only 70% as likely to get Premium as Urban
```

| DIR Value | Interpretation |
|-----------|---------------|
| 0.80 – 1.20 | Fair — compliant with the 4/5ths rule |
| < 0.80 | Alert — disparate impact detected |
| > 1.20 | Alert — reverse disparity |

### 4. Prometheus Integration and Real-Time Alerting

TrustyAI emits metrics to Prometheus via the OpenShift user workload monitoring stack. PrometheusRules define alert thresholds that fire automatically when bias is detected — no human watching dashboards required.

```yaml
# Alert fires when SPD exceeds ±0.15
- alert: NetworkSliceBiasDetected
  expr: abs(trustyai_spd_live{model="network-slice-model"}) > 0.15
  for: 1m
  labels:
    severity: critical
```

**Business value:** Bias detection is automated. The on-call engineer gets paged for bias the same way they get paged for a service outage.

### 5. Grafana Dashboard — Live Bias Lifecycle Visualization

The demo includes a Grafana dashboard (deployed in the OpenShift console) showing the complete bias lifecycle:

- **Inferences Monitored** — total observations TrustyAI has logged
- **SPD (live)** — real-time SPD with fair/warning/alert threshold bands
- **DIR (live)** — real-time DIR with compliance threshold

As the demo progresses — baseline → bias injection → retraining → verification — the dashboard shows the full arc in real time. Three labeled data series per panel (`baseline`, `biased`, `fair`) tell the complete story visually.

### 6. KFP-Integrated Automated Remediation

When bias is detected, TrustyAI's metrics feed directly into a KFP (Kubeflow Pipelines) workflow that:

1. Reads current SPD and DIR from TrustyAI metrics
2. Evaluates against configured thresholds
3. Triggers a fair retraining job if either threshold is breached
4. Uploads the retrained model to MinIO
5. The KServe InferenceService auto-reloads the new model

**Business value:** The detection-to-fix cycle is fully automated. No human intervention required between alert and remediation.

---

## Why TrustyAI vs. Alternatives

### vs. Building Your Own Fairness Monitoring

| Aspect | Build Your Own | TrustyAI |
|--------|---------------|---------|
| Inference logging | Requires model changes | Zero code changes |
| Metrics computation | Custom implementation | Built-in SPD, DIR, and more |
| Prometheus integration | Custom exporters needed | Native integration |
| OpenShift integration | Significant integration work | Ships with RHOAI |
| Regulatory auditability | Varies | Designed for it |
| Maintenance burden | Full team ownership | Red Hat supported |

### vs. Third-Party AI Governance Platforms

| Aspect | Third-Party Platforms | TrustyAI |
|--------|--------------------|---------|
| Deployment model | SaaS / external | On-cluster, no data leaves |
| Data privacy | Data sent to third party | All inference data stays on-premise |
| OpenShift integration | Adapter/connector required | Native RHOAI component |
| Cost | Per-inference or seat licensing | Included with RHOAI subscription |
| Latency overhead | Additional network hop | In-cluster, sub-millisecond |

For telecom operators with regulatory data residency requirements or classified inference data, keeping fairness monitoring on-cluster with TrustyAI is not a preference — it is a compliance requirement.

---

## The OpenShift AI Advantage

TrustyAI is not a standalone product — it is a first-class component of Red Hat OpenShift AI. This means:

**Integrated deployment:** TrustyAI is deployed as a Kubernetes Custom Resource (`TrustyAIService`). One YAML file. No separate installation, licensing, or configuration.

**Operator-managed:** The OpenShift AI operator manages TrustyAI upgrades, scaling, and configuration alongside all other RHOAI components.

**Unified monitoring:** TrustyAI metrics flow into the same Prometheus stack as all other OpenShift application metrics. One monitoring plane for both application health and AI fairness.

**Native model server integration:** TrustyAI automatically detects and monitors any InferenceService with the `trustyai.opendatahub.io/monitoring: "true"` label — no changes to model deployment manifests beyond adding that label.

---

## Metrics at a Glance

The Prometheus queries used in this demo:

```promql
# Total inferences logged by TrustyAI
sum(trustyai_model_observations_total{model="network-slice-model"}) by (model)

# Live SPD (all stages: baseline, biased, fair)
trustyai_spd_live{model="network-slice-model"}

# Live DIR (all stages)
trustyai_dir_live{model="network-slice-model"}
```

These queries power the Grafana dashboard panels and the PrometheusRule alert expressions.

---

## Summary: The TrustyAI Value Stack

```
REGULATORY COMPLIANCE
  ← Documented audit trail of every AI decision
  ← Automated bias detection aligned to FCC/Ofcom/EU AI Act thresholds
  ← PrometheusRule alerts that prove active monitoring was in place

OPERATIONAL EFFICIENCY
  ← Zero model changes required to enable monitoring
  ← Automated detection-to-remediation pipeline via KFP
  ← On-call alerting for bias the same as for outages

BUSINESS RISK REDUCTION
  ← Catch discrimination before customers or regulators do
  ← Quantify fairness improvement after retraining
  ← Full lifecycle visibility from bias detection to verified fix

PLATFORM ADVANTAGE
  ← Native RHOAI component — no additional licensing
  ← On-cluster — no data leaves your environment
  ← Unified monitoring with existing Prometheus/Grafana infrastructure
```

> **One-liner for the audience:**
> "TrustyAI gives your AI-driven network operations a built-in fairness auditor — watching every allocation decision in real time, automatically alerting when geographic bias is detected, and triggering retraining before anyone files a regulatory complaint."
