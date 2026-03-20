# Technical Architecture

## Overview

The demo deploys a complete AI fairness monitoring system on Red Hat OpenShift AI using KServe (RawDeployment), TrustyAI, Prometheus, and Grafana. No service mesh (OSSM/Istio) is required.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Red Hat OpenShift AI                                │
│                                                                             │
│  ┌──────────────┐     ┌──────────────────────────────────────┐             │
│  │  Data Science │     │         telco-bias-demo namespace    │             │
│  │  Workbench    │     │                                      │             │
│  │               │────>│  MinIO S3  ──>  KServe OVMS          │             │
│  │  Notebook     │     │  (models)       (predictor pod)      │             │
│  │  cells 1–12   │     │                   │                  │             │
│  └──────────────┘     │            KServe Agent (9081)        │             │
│          │            │              │          │             │             │
│          │            │              v          v             │             │
│          │            │         OVMS Model  TrustyAI         │             │
│          │            │         (port 8888) Service          │             │
│          │            │                        │             │             │
│          │            │              Prometheus Pushgateway  │             │
│          │            │              (SPD/DIR pushed here)   │             │
│          └────────────┤                        │             │             │
│                       │              Prometheus (UWM)        │             │
│                       │                        │             │             │
│                       │              Grafana Dashboard       │             │
│                       │              PrometheusRule Alerts   │             │
│                       └──────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Breakdown

### 1. Data Science Workbench (Notebook)

The notebook is the control plane for the entire demo. It runs as a Jupyter pod in the `rhoai-demo` project and uses `oc` CLI via `subprocess` to manage resources in `telco-bias-demo` namespace.

**Workbench service account:** `telco-wb` (in `rhoai-demo` project)
**Demo namespace:** `telco-bias-demo`

The notebook:
- Trains the MLP model and exports to ONNX
- Deploys all Kubernetes resources
- Seeds inferences via `oc exec` into the predictor pod
- Computes SPD and DIR from model predictions
- Pushes metrics to Prometheus Pushgateway

### 2. MinIO S3 (Persistent Model Storage)

MinIO is deployed as a `Deployment` with a `PersistentVolumeClaim` (2Gi) for model storage that survives pod restarts.

```
s3://models/network-slice-model/1/model.onnx
```

A TLS Edge Route (`minio-s3`) is created so the KServe storage-initializer can download the model over HTTPS (required by KServe in RHOAI 2.x).

| Resource | Details |
|----------|---------|
| Image | `quay.io/trustyai_testing/modelmesh-minio-examples:latest` |
| Storage | PVC 2Gi (ReadWriteOnce) |
| Route | TLS Edge → port 9000 |
| Secret | `aws-connection-minio-data-connection` |

### 3. OVMS ServingRuntime + InferenceService

The model is served using OpenVINO Model Server (OVMS) in KServe RawDeployment mode.

**ServingRuntime:** `ovms-runtime`
- Protocol: v2 (REST + gRPC)
- Model format: ONNX v1
- Ports: 8888 (REST), 8001 (gRPC)

**InferenceService:** `network-slice-model`
- Deployment mode: `RawDeployment` (no Istio sidecar)
- SA: `kserve-minio-sa` (annotated with MinIO TLS route endpoint)
- Label: `trustyai.opendatahub.io/monitoring: "true"` (enables TrustyAI auto-patching)

### 4. KServe Agent

The KServe agent runs as a sidecar container in the predictor pod (port 9081). It intercepts every inference request, proxies it to the OVMS model server (port 8888), and simultaneously POSTs a copy of the input/output to TrustyAI.

```
oc exec → pod → localhost:9081 (agent)
                     │
                     ├──> localhost:8888 (OVMS) → prediction
                     │
                     └──> TrustyAI service (HTTPS) → logged
```

**Why oc exec instead of external route?**
In RawDeployment mode, the predictor pod's agent port (9081) is only accessible inside the cluster. The workbench cannot reach it cross-namespace directly. `oc exec` provides a reliable path that works regardless of route configuration.

**CA Bundle:**
The agent verifies TrustyAI's TLS certificate using the OpenShift service CA. The `kserve-logger-ca-bundle` ConfigMap is created from `openshift-service-ca.crt` and mounted at `/etc/tls/logger/service-ca.crt`. The `inferenceservice-config` ConfigMap in `redhat-ods-applications` is patched to reference this bundle.

### 5. TrustyAI Service

TrustyAI is deployed as a `TrustyAIService` CR, managed by the TrustyAI operator (part of RHOAI).

```yaml
spec:
  storage:
    format: PVC
    folder: /data
    size: 1Gi
  data:
    filename: data.csv
    format: CSV
  metrics:
    schedule: "5s"
    batchSize: 5000
```

**Deployment order is critical:** TrustyAI must be deployed **before** the InferenceService. The TrustyAI operator watches for ISVCs labeled with `trustyai.opendatahub.io/monitoring: "true"` and patches the predictor deployment to mount the logger CA bundle. If ISVC is deployed first, the patch may not be applied correctly.

TrustyAI exposes:
- `/info` — registered models and observation counts
- `/info/names` — name mapping for readable column names
- `/metrics/group/fairness/spd/request` — register scheduled SPD monitor
- `/metrics/group/fairness/dir/request` — register scheduled DIR monitor
- `/q/metrics` — Prometheus metrics endpoint (scraped by ServiceMonitor)

### 6. Prometheus Pushgateway

The Pushgateway is deployed as a `Deployment` + `Service` in `telco-bias-demo` namespace. It acts as a metrics collection point for batch/notebook jobs that cannot be scraped directly.

The notebook pushes SPD and DIR values to the Pushgateway after each key step (baseline, biased, fair) using labeled time series:

```
trustyai_spd_live{model="network-slice-model", step="baseline", protected="Region"} 0.12
trustyai_dir_live{model="network-slice-model", step="baseline", protected="Region"} 0.61
```

The three `step` label values create three distinct series per panel in Grafana, showing the complete bias lifecycle in a single time-series chart.

**Push endpoint:**
```
POST http://pushgateway.telco-bias-demo.svc.cluster.local:9091
     /metrics/job/bias-monitor/model/network-slice-model
```

### 7. Prometheus (User Workload Monitoring)

OpenShift's user workload monitoring stack scrapes metrics from `telco-bias-demo` namespace. Two `ServiceMonitor` resources are deployed:

| ServiceMonitor | Target | Interval |
|---------------|--------|---------|
| `pushgateway-monitor` | Pushgateway port 9091 | 15s |
| `trustyai-bias-monitor` | TrustyAI `/q/metrics` | 30s |

A `PrometheusRule` defines two alert conditions:

```yaml
# SPD alert — fires when geographic bias exceeds ±0.15
- alert: NetworkSliceBiasDetected
  expr: abs(trustyai_spd_live{model="network-slice-model"}) > 0.15

# DIR alert — fires when disparate impact is below 0.80
- alert: DIRBelowThreshold
  expr: trustyai_dir_live{model="network-slice-model"} < 0.80
```

### 8. Grafana Dashboard

The Grafana dashboard is deployed as a `ConfigMap` in `openshift-config-managed` namespace with the label `console.openshift.io/dashboard: "true"`, which causes the OpenShift console to automatically load it in Observe → Dashboards.

**Dashboard UID:** `trustyai-bias-005`
**Panels (3):**

| Panel | Query | Type |
|-------|-------|------|
| Inferences Monitored | `sum(trustyai_model_observations_total{...}) by (model)` | graph |
| SPD — Statistical Parity Difference | `trustyai_spd_live{...}` | graph |
| DIR — Disparate Impact Ratio | `trustyai_dir_live{...}` | graph |

The `legendFormat` uses `SPD ({{step}})` / `DIR ({{step}})` which renders as `SPD (baseline)`, `SPD (biased)`, `SPD (fair)` — three labeled series that show the full bias lifecycle.

---

## Deployment Sequence

The correct order for reliable TrustyAI inference logging:

```
1. Create kserve-logger-ca-bundle ConfigMap
        ↓
2. Deploy TrustyAI (TrustyAIService CR)
        ↓
3. Wait for TrustyAI pod → Running
        ↓
4. Deploy InferenceService (ISVC)
        ↓  TrustyAI operator detects ISVC, patches predictor deployment
5. Wait for ISVC → Loaded
        ↓
6. Wait 30s for TrustyAI to patch predictor pod (volume mount applied)
        ↓
7. Seed inferences via oc exec → localhost:9081 (agent → model → TrustyAI)
        ↓
8. Wait for TrustyAI /info to show model with observations > 0
```

---

## Model Architecture

| Aspect | Detail |
|--------|--------|
| Type | Multi-Layer Perceptron (MLPClassifier, scikit-learn) |
| Architecture | Input (7) → Hidden (64) → Hidden (32) → Output (3 classes) |
| Task | Multi-class classification: Tier 0, 1, 2 |
| Export | ONNX via `skl2onnx`, opset 12 |
| Post-processing | ZipMap stripped → ArgMax → Cast(FP32) |
| Serving | OVMS (OpenVINO Model Server) |

**Input features:**

| Feature | Type | Description |
|---------|------|-------------|
| tenure | float | Months as subscriber |
| MonthlyCharges | float | Monthly bill ($20–$120) |
| TotalCharges | float | Cumulative charges |
| ContractType | float | 0=month-to-month, 1=1yr, 2=2yr |
| PaymentMethod | float | 0–3 (payment type) |
| Region_enc | float | 0=Urban, 1=Suburban, 2=Rural |
| Income_enc | float | 0=High, 1=Medium, 2=Low |

**Why ArgMax + Cast(FP32)?**

When scikit-learn exports an MLP to ONNX, the raw output is a table of probabilities — one per class — wrapped in a node called `ZipMap`:

```
ZipMap output: {"0": 0.12, "1": 0.25, "2": 0.63}   ← probability per tier
```

This causes two problems:
- OVMS does not support `ZipMap` and refuses to serve the model
- TrustyAI needs a single predicted class number, not a dictionary

The fix is two steps:

1. **ArgMax** — picks the class with the highest probability (the winner)
```
[0.12, 0.25, 0.63]  →  ArgMax  →  2        (Tier 2 has highest probability)
```

2. **Cast(FP32)** — converts the result from an integer to a decimal number
```
2  →  Cast(FP32)  →  2.0      (TrustyAI only accepts float values for logging)
```

Without ArgMax + Cast(FP32), the model either won't serve or TrustyAI logs nothing — both silent failures with no error messages.

---

## Network Topology

```
rhoai-demo namespace          telco-bias-demo namespace
─────────────────             ────────────────────────────────────────────
telco-wb pod                  minio (port 9000)
  │                           minio-s3 Route (TLS) → minio:9000
  │── oc exec ──────────────> network-slice-model-predictor pod
  │                             ├── kserve-container (OVMS, port 8888)
  │                             └── agent (port 9081)
  │                                    │
  │                                    └──> trustyai-service pod (port 80)
  │                                              │
  │                                              v
  │── HTTP POST ─────────────> pushgateway (port 9091)
                                        │
                              openshift-monitoring namespace
                                        │
                              Prometheus (scrapes pushgateway + trustyai)
                                        │
                              openshift-config-managed namespace
                                        │
                              Grafana dashboard ConfigMap
```

---

## Data Flow Summary

| Step | From | To | Protocol | What |
|------|------|----|---------|------|
| Model upload | Notebook | MinIO | HTTP (boto3) | ONNX file |
| Model download | MinIO Route | OVMS pod | HTTPS | ONNX file at startup |
| Inference request | Notebook (oc exec) | Agent port 9081 | HTTP | Feature vector |
| Inference proxy | Agent | OVMS port 8888 | HTTP | Feature vector → prediction |
| Inference log | Agent | TrustyAI port 443 | HTTPS | Input + output payload |
| SPD/DIR push | Notebook | Pushgateway port 9091 | HTTP | Prometheus text format |
| Metrics scrape | Prometheus | Pushgateway + TrustyAI | HTTP | Prometheus scrape |
| Dashboard query | Grafana | Prometheus | HTTP | PromQL |
