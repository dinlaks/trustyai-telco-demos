#!/usr/bin/env bash
# preflight.sh — Validates all prerequisites before running any TrustyAI demo notebook.
# Run as cluster-admin from the repo root: bash shared/preflight.sh

set -euo pipefail

PASS="[PASS]"
FAIL="[FAIL]"
WARN="[WARN]"
ERRORS=0

fail() { echo "$FAIL $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "$PASS $1"; }
warn() { echo "$WARN $1"; }
header() { echo ""; echo "==> $1"; }

# ---------------------------------------------------------------------------
# 1. Local CLI tools
# ---------------------------------------------------------------------------
header "Local CLI Tools"

if command -v oc &>/dev/null; then
  pass "oc CLI found: $(oc version --client -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["releaseClientVersion"])' 2>/dev/null || oc version --client | head -1)"
else
  fail "oc CLI not found — install OpenShift CLI before proceeding"
fi

if command -v python3 &>/dev/null; then
  pass "python3 found: $(python3 --version)"
else
  fail "python3 not found — required for patch-kserve.py"
fi

# ---------------------------------------------------------------------------
# 2. Cluster access and version
# ---------------------------------------------------------------------------
header "Cluster Access and Version"

if ! oc whoami &>/dev/null; then
  fail "Not logged in to an OpenShift cluster — run 'oc login' first"
  echo ""
  echo "Aborting: cannot proceed without cluster access."
  exit 1
fi
pass "Logged in as: $(oc whoami)"

OCP_VERSION=$(oc version -o json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("openshiftVersion","unknown"))' 2>/dev/null || echo "unknown")
MAJOR=$(echo "$OCP_VERSION" | cut -d. -f1)
MINOR=$(echo "$OCP_VERSION" | cut -d. -f2)
if [[ "$MAJOR" -ge 4 && "$MINOR" -ge 20 ]]; then
  pass "OpenShift version: $OCP_VERSION (>= 4.20 required)"
else
  fail "OpenShift version: $OCP_VERSION — requires 4.20 or higher"
fi

if oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  pass "cluster-admin privileges confirmed"
else
  fail "cluster-admin privileges required — current user does not have full cluster access"
fi

# ---------------------------------------------------------------------------
# 3. Wave 0 — Foundation operators
# ---------------------------------------------------------------------------
header "Wave 0 — Foundation Operators"

check_csv() {
  local ns="$1" label="$2"
  local phase
  phase=$(oc get csv -n "$ns" -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | tail -1)
  if [[ "$phase" == "Succeeded" ]]; then
    pass "$label operator: Succeeded"
  elif [[ -z "$phase" ]]; then
    fail "$label operator: not found in namespace $ns"
  else
    fail "$label operator: $phase (expected Succeeded)"
  fi
}

check_csv "openshift-nfd"        "Node Feature Discovery (NFD)"
check_csv "cert-manager-operator" "cert-manager"

SM_PHASE=$(oc get csv -n openshift-operators -o jsonpath='{.items[*].status.phase}' 2>/dev/null \
  | tr ' ' '\n' | grep -v '^$' | tail -1)
SM_CSV=$(oc get csv -n openshift-operators 2>/dev/null | grep -i servicemesh | awk '{print $1}' | head -1)
if [[ -n "$SM_CSV" && "$SM_PHASE" == "Succeeded" ]]; then
  pass "OpenShift Service Mesh operator: Succeeded ($SM_CSV)"
else
  fail "OpenShift Service Mesh operator: not found or not Succeeded"
fi

SL_PHASE=$(oc get csv -n openshift-serverless 2>/dev/null | grep serverless | awk '{print $NF}' | head -1)
if [[ "$SL_PHASE" == "Succeeded" ]]; then
  pass "OpenShift Serverless operator: Succeeded"
elif [[ -z "$SL_PHASE" ]]; then
  fail "OpenShift Serverless operator: not found in openshift-serverless namespace"
else
  fail "OpenShift Serverless operator: $SL_PHASE (expected Succeeded)"
fi

# GPU operator is optional
GPU_CSV=$(oc get csv -n nvidia-gpu-operator 2>/dev/null | grep gpu | awk '{print $1}' | head -1)
if [[ -n "$GPU_CSV" ]]; then
  pass "NVIDIA GPU operator: found ($GPU_CSV)"
else
  warn "NVIDIA GPU operator: not found (optional — skip if no GPU nodes)"
fi

# ---------------------------------------------------------------------------
# 4. Wave 1 — RHOAI
# ---------------------------------------------------------------------------
header "Wave 1 — RHOAI Operator"

RHOAI_CSV=$(oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods | awk '{print $1}' | head -1)
RHOAI_PHASE=$(oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods | awk '{print $NF}' | head -1)
if [[ "$RHOAI_PHASE" == "Succeeded" ]]; then
  pass "RHOAI operator: Succeeded ($RHOAI_CSV)"
else
  fail "RHOAI operator: not found or not Succeeded in redhat-ods-operator namespace"
fi

AUTHORINO=$(oc get csv -n openshift-operators 2>/dev/null | grep authorino | awk '{print $NF}' | head -1)
if [[ "$AUTHORINO" == "Succeeded" ]]; then
  pass "Authorino operator: Succeeded"
else
  fail "Authorino operator: not found or not Succeeded"
fi

# ---------------------------------------------------------------------------
# 5. DataScienceCluster — TrustyAI + KServe
# ---------------------------------------------------------------------------
header "DataScienceCluster Components"

DSC_PHASE=$(oc get datasciencecluster default -n redhat-ods-operator \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$DSC_PHASE" == "Ready" ]]; then
  pass "DataScienceCluster: Ready"
else
  fail "DataScienceCluster: '$DSC_PHASE' (expected Ready) — apply shared/operators/post-install/01-datasciencecluster.yaml"
fi

TRUSTYAI_STATE=$(oc get datasciencecluster default -n redhat-ods-operator \
  -o jsonpath='{.spec.components.trustyai.managementState}' 2>/dev/null || echo "")
if [[ "$TRUSTYAI_STATE" == "Managed" ]]; then
  pass "TrustyAI component: Managed"
else
  fail "TrustyAI component: '$TRUSTYAI_STATE' (expected Managed)"
fi

KSERVE_STATE=$(oc get datasciencecluster default -n redhat-ods-operator \
  -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || echo "")
if [[ "$KSERVE_STATE" == "Managed" ]]; then
  pass "KServe component: Managed"
else
  fail "KServe component: '$KSERVE_STATE' (expected Managed)"
fi

DEPLOY_MODE=$(oc get datasciencecluster default -n redhat-ods-operator \
  -o jsonpath='{.spec.components.kserve.defaultDeploymentMode}' 2>/dev/null || echo "")
if [[ "$DEPLOY_MODE" == "RawDeployment" ]]; then
  pass "KServe deployment mode: RawDeployment"
else
  warn "KServe deployment mode: '$DEPLOY_MODE' (expected RawDeployment for this demo)"
fi

# ---------------------------------------------------------------------------
# 6. User workload monitoring
# ---------------------------------------------------------------------------
header "User Workload Monitoring"

UWM=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c "enableUserWorkload: true" || echo "0")
if [[ "$UWM" -ge 1 ]]; then
  pass "User workload monitoring: enabled"
else
  fail "User workload monitoring: not enabled — apply shared/operators/post-install/02-user-workload-monitoring.yaml"
fi

# ---------------------------------------------------------------------------
# 7. Demo namespace and workbench service account
# ---------------------------------------------------------------------------
header "Demo Project and Workbench"

RHOAI_PROJECT="rhoai-demo"
WORKBENCH_SA="telco-wb"

if oc get project "$RHOAI_PROJECT" &>/dev/null; then
  pass "RHOAI demo project '$RHOAI_PROJECT': exists"
else
  fail "RHOAI demo project '$RHOAI_PROJECT': not found — create the project and workbench in the RHOAI dashboard"
fi

if oc get sa "$WORKBENCH_SA" -n "$RHOAI_PROJECT" &>/dev/null; then
  pass "Workbench service account '$WORKBENCH_SA': exists in $RHOAI_PROJECT"
else
  fail "Workbench service account '$WORKBENCH_SA': not found in $RHOAI_PROJECT — start the workbench from the RHOAI dashboard first"
fi

# ---------------------------------------------------------------------------
# 8. KServe inferenceservice-config CA bundle patch
# ---------------------------------------------------------------------------
header "KServe CA Bundle Patch"

CA_BUNDLE=$(oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='{.data.logger}' 2>/dev/null | python3 -c \
  'import sys,json; d=json.load(sys.stdin); print(d.get("caBundle",""))' 2>/dev/null || echo "")
if [[ "$CA_BUNDLE" == "kserve-logger-ca-bundle" ]]; then
  pass "KServe CA bundle patch: applied (caBundle=kserve-logger-ca-bundle)"
else
  fail "KServe CA bundle patch: not applied — run 'python3 shared/patch-kserve.py'"
fi

# ---------------------------------------------------------------------------
# 9. Container image reachability
# ---------------------------------------------------------------------------
header "Container Image Reachability"

check_image() {
  local image="$1" label="$2"
  if oc run preflight-img-check --image="$image" --restart=Never \
       --command -- echo ok -n default --dry-run=server &>/dev/null 2>&1; then
    pass "$label: reachable"
  else
    warn "$label: could not verify reachability (check registry access manually)"
  fi
}

check_image "quay.io/modh/openvino_model_server:stable" "OpenVINO Model Server (OVMS)"
check_image "quay.io/trustyai_testing/modelmesh-minio-examples:latest" "MinIO (TrustyAI testing)"
check_image "prom/pushgateway:latest" "Prometheus Pushgateway"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
if [[ "$ERRORS" -eq 0 ]]; then
  echo "$PASS All preflight checks passed. Ready to run the demo notebook."
else
  echo "$FAIL $ERRORS check(s) failed. Resolve the issues above before proceeding."
fi
echo "=================================================="
echo ""

exit "$ERRORS"
