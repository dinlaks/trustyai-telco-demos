# Prerequisites

Complete all steps in this guide before running the demo notebook.

---

## 1. Environment Requirements

| Requirement | Version / Details |
|------------|-----------------|
| Red Hat OpenShift AI | 2.x and 3.x (**validated on 2.25 and 3.3**) |
| OpenShift Cluster | 4.18+ (**validated on 4.20**) |
| TrustyAI Operator | Enabled in RHOAI DSC |
| KServe | RawDeployment mode (no OSSM/Istio required) |
| Data Science Pipelines | Optional (required for Cell 11a KFP path only) |

> **Note:** This demo is validated on RHOAI 2.25 with KServe RawDeployment (no service mesh). OSSM/Istio configuration is NOT required.

---

## 2. RHOAI Operator Configuration

Ensure the following components are enabled in the `DataScienceCluster` CR:

```yaml
spec:
  components:
    trustyai:
      managementState: Managed
    kserve:
      managementState: Managed
      serving:
        managementState: Managed
        name: knative-serving
    datasciencepipelines:
      managementState: Managed   # Optional — needed for Cell 11a only
```

Verify TrustyAI operator is running:

```bash
oc get pod -n redhat-ods-applications -l app.kubernetes.io/name=trustyai-service-operator
```

---

## 3. Workbench Setup

Create a workbench in the RHOAI dashboard:

| Setting | Value |
|---------|-------|
| Project | `rhoai-demo` |
| Workbench name | `telco-wb` |
| Image | Standard Data Science (Python 3.11) |
| Container size | Medium (4 CPU / 8Gi RAM) |
| Storage | 20Gi PVC |

The workbench service account will be named `telco-wb` and scoped to project `rhoai-demo`.

---

## 4. Cluster-Admin Pre-Requisites

Run the following commands **once** as cluster-admin before executing the notebook. These are also provided in `setup/cluster-admin-setup.sh`.

```bash
# 1. Allow workbench SA to create new projects
oc adm policy add-cluster-role-to-user self-provisioner \
  system:serviceaccount:rhoai-demo:telco-wb

# 2. Allow workbench SA to read cluster-wide resources
oc adm policy add-cluster-role-to-user cluster-reader \
  system:serviceaccount:rhoai-demo:telco-wb

# 3. Create the demo namespace
oc new-project telco-bias-demo 2>/dev/null || true

# 4. Grant workbench SA admin on the demo namespace
oc adm policy add-role-to-user admin \
  system:serviceaccount:rhoai-demo:telco-wb -n telco-bias-demo

# 5. Allow SA to create ServiceMonitors and PrometheusRules
#    (required for Cell 8 — Prometheus monitoring setup)
oc adm policy add-role-to-user monitoring-edit \
  system:serviceaccount:rhoai-demo:telco-wb -n telco-bias-demo

# 6. Allow SA to apply Grafana dashboard ConfigMap
#    (required for Cell 8b — applies dashboard to openshift-config-managed)
oc adm policy add-role-to-user admin \
  system:serviceaccount:rhoai-demo:telco-wb -n openshift-config-managed
```

Verify all bindings:

```bash
echo "=== Cluster-wide bindings for telco-wb ==="
oc get clusterrolebinding | grep telco-wb

echo "=== Namespace bindings in telco-bias-demo ==="
oc get rolebinding -n telco-bias-demo | grep telco-wb

echo "=== Namespace binding in openshift-config-managed ==="
oc get rolebinding -n openshift-config-managed | grep telco-wb
```

---

## 5. KServe CA Bundle Patch (Required)

KServe's agent needs a CA bundle configuration to verify TrustyAI's TLS certificate when logging inferences. Without this, the agent cannot POST to TrustyAI and no inference data is logged.

Run once as cluster-admin:

```bash
python3 setup/patch-kserve.py
```

This patches `inferenceservice-config` in `redhat-ods-applications` to add the `caBundle: kserve-logger-ca-bundle` configuration to the logger settings.

Verify the patch was applied:

```bash
oc get configmap inferenceservice-config \
  -n redhat-ods-applications \
  -o jsonpath='{.data.logger}' | python3 -m json.tool | grep -A2 caBundle
```

Expected output:

```json
"caBundle": "kserve-logger-ca-bundle",
"caCertFile": "service-ca.crt",
```

> **Note:** Cell 1 of the notebook also attempts this patch automatically. If it fails (due to insufficient permissions), run `patch-kserve.py` manually as cluster-admin.

---

## 6. User Workload Monitoring (for Prometheus/Grafana)

User workload monitoring must be enabled for Prometheus to scrape metrics from `telco-bias-demo` namespace. Cell 8b of the notebook applies this automatically, but it requires the cluster-admin binding set up in step 4 (#6).

If it fails in the notebook, apply manually as cluster-admin:

```bash
oc apply -f setup/user-workload-monitoring.yaml
```

Verify it is enabled:

```bash
oc get configmap cluster-monitoring-config \
  -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'
```

Expected output includes: `enableUserWorkload: true`

---

## 7. Python Dependencies

The notebook installs all dependencies in Cell 2. For reference:

```
scikit-learn
pandas
numpy
boto3
skl2onnx
onnxruntime
matplotlib
seaborn
requests
kfp>=2.14.5
kubernetes>=27.2.0
protobuf>=6.31.1,<7.0
```

These are installed into the workbench container via `pip install` in Cell 2. No pre-installation on the cluster is required.

---

## 8. Image Availability

The demo uses the following container images that must be reachable from the cluster:

| Image | Used For |
|-------|---------|
| `quay.io/modh/openvino_model_server@sha256:6c779...` | OVMS ServingRuntime |
| `quay.io/trustyai_testing/modelmesh-minio-examples:latest` | MinIO storage |
| `prom/pushgateway:latest` | Prometheus Pushgateway |

If the cluster has restricted internet access, pre-pull these images to an internal registry and update the references in Cell 1 of the notebook.

---

## 9. oc CLI Access from Workbench

The notebook uses `subprocess` to call `oc` commands directly. Verify `oc` is available in the workbench terminal:

```bash
oc version
oc whoami
```

The workbench pod inherits the service account token for `telco-wb`, which is used for all `oc` and API calls in the notebook.

---

## Pre-Demo Checklist

Before starting the demo, confirm:

- [ ] Cluster-admin pre-requisites (steps 1-6) are complete
- [ ] KServe CA bundle patch is applied (step 5)
- [ ] Workbench `telco-wb` is running in project `rhoai-demo`
- [ ] Notebook `telco-bias-demo-final.ipynb` is uploaded
- [ ] Container images are reachable from the cluster
- [ ] `oc whoami` works from the workbench terminal

---

## Troubleshooting

### TrustyAI not logging inferences

```bash
# Check agent logs in predictor pod
oc logs -n telco-bias-demo \
  -l serving.kserve.io/inferenceservice=network-slice-model \
  -c agent --tail=20

# Verify CA bundle is mounted
oc exec -n telco-bias-demo \
  $(oc get pod -n telco-bias-demo \
    -l serving.kserve.io/inferenceservice=network-slice-model \
    -o jsonpath='{.items[0].metadata.name}') \
  -c agent -- ls /etc/tls/logger/
```

### MinIO TLS connection refused after pod restart

After MinIO pod restarts, the route host may change. Re-run Cell 1 to refresh the SA annotation with the current route host.

### Grafana dashboard not visible in OpenShift console

Verify the ConfigMap was applied to `openshift-config-managed`:

```bash
oc get configmap trustyai-bias-dashboard -n openshift-config-managed
```

If missing, run Cell 8b again, or apply manually:

```bash
oc apply -f setup/grafana-bias-dashboard.yaml
```
