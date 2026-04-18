#!/usr/bin/env bash
# =============================================================================
# deploy-prereqs.sh
# =============================================================================
# Full end-to-end pre-requisite setup for the TrustyAI Telco Bias demo.
# Run ONCE as cluster-admin from the repo root:
#
#   bash shared/deploy-prereqs.sh
#
# Steps (in order):
#   1.  Sanity checks — oc logged in, cluster-admin, python3
#   2.  Wave 0 — NFD, cert-manager, Service Mesh 2.x, Serverless subscriptions
#   3.  Wait  — Wave 0 CSVs reach Succeeded
#   4.  Wave 1 — RHOAI 2.25 + Authorino subscriptions
#   5.  Wait  — Wave 1 CSVs reach Succeeded
#   6.  Post-install — DataScienceCluster CR + user workload monitoring
#   7.  Wait  — DataScienceCluster reaches Ready
#   8.  Create rhoai-demo Data Science Project
#   9.  Wait for ODH notebook controller mutating webhook
#   10. Create workbench PVC + Notebook CR (telco-wb)
#   11. Wait  — workbench pod Running (2/2 with OAuth proxy)
#   12. Preflight validation
#   13. Patch — KServe CA bundle (marks inferenceservice-config as unmanaged + adds caBundle)
#
# Prerequisites:
#   - oc CLI installed and logged in as cluster-admin
#   - python3 available (for patch-kserve.py)
#   - Run from the repo root: trustyai-telco-demos/
#
# Override defaults via env vars:
#   RHOAI_PROJECT, WORKBENCH_SA, NAMESPACE, WAVE_TIMEOUT, DSC_TIMEOUT, WB_TIMEOUT
#
# Validated on: OpenShift 4.18+ + RHOAI 2.25 + OSSM 2.x
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
RHOAI_PROJECT="${RHOAI_PROJECT:-rhoai-demo}"
WORKBENCH_SA="${WORKBENCH_SA:-telco-wb}"
DEMO_NS="${NAMESPACE:-telco-bias-demo}"
WAVE_TIMEOUT="${WAVE_TIMEOUT:-600}"   # seconds to wait per CSV wave
DSC_TIMEOUT="${DSC_TIMEOUT:-900}"     # DataScienceCluster may take longer
WB_TIMEOUT="${WB_TIMEOUT:-300}"       # workbench pod startup

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'

header() { echo ""; echo -e "${BOLD}==> $*${RESET}"; }
info()   { echo "    $*"; }
ok()     { echo -e "    ${GREEN}OK${RESET}  $*"; }
warn()   { echo -e "    ${YELLOW}WARN${RESET} $*"; }
die()    { echo -e "\n    ${RED}ERROR${RESET} $*" >&2; exit 1; }

# Returns true if a CSV matching pattern is Succeeded in ANY of the given namespaces.
csv_succeeded_any() {
  local pattern="$1"; shift
  local ns phase
  for ns in "$@"; do
    phase=$(oc get csv -n "$ns" 2>/dev/null | grep -i "$pattern" | awk '{print $NF}' | head -1 || true)
    [[ "$phase" == "Succeeded" ]] && return 0
  done
  return 1
}

# Returns true if a CSV matching pattern is Succeeded in the given namespace.
csv_succeeded() {
  local ns="$1" pattern="$2"
  csv_succeeded_any "$pattern" "$ns"
}

# Returns true if a Subscription matching pattern exists in ANY of the given namespaces.
subscription_exists_any() {
  local pattern="$1"; shift
  local ns
  for ns in "$@"; do
    oc get subscription -n "$ns" 2>/dev/null | grep -qi "$pattern" && return 0
  done
  return 1
}

# Returns true if a Subscription matching pattern exists in the given namespace.
subscription_exists() {
  local ns="$1" pattern="$2"
  subscription_exists_any "$pattern" "$ns"
}

# Skip if CSV is already Succeeded OR a subscription already exists.
# Use this for any operator that installs into a single known namespace.
apply_if_needed() {
  local ns="$1" pattern="$2" label="$3" file="$4"
  if csv_succeeded "$ns" "$pattern"; then
    ok "${label} already installed — skipping"
  elif subscription_exists "$ns" "$pattern"; then
    warn "${label} subscription already exists (CSV not yet Succeeded) — skipping re-apply"
  else
    info "Applying ${label} subscription..."
    oc apply -f "$file"
  fi
}

# Install cert-manager — checks CSV and subscription across all namespaces
# it may have been installed in, and removes duplicate OperatorGroups.
install_cert_manager() {
  # Skip if cert-manager is already Succeeded in any namespace it may live in.
  if csv_succeeded_any "cert-manager" \
      cert-manager-operator cert-manager openshift-operators; then
    ok "cert-manager already installed — skipping"
    return 0
  fi

  # Skip if a subscription already exists in any relevant namespace.
  if subscription_exists_any "cert-manager" \
      cert-manager-operator cert-manager openshift-operators; then
    warn "cert-manager subscription already exists (CSV not yet Succeeded) — skipping re-apply"
    return 0
  fi

  # Fix duplicate OperatorGroups — OLM leaves CSV in Unknown when > 1 OG exists.
  local og_count
  og_count=$(oc get operatorgroup -n cert-manager-operator \
    --no-headers 2>/dev/null | wc -l | xargs)
  if [[ "${og_count:-0}" -gt 1 ]]; then
    warn "Found ${og_count} OperatorGroups in cert-manager-operator — removing duplicates..."
    oc delete operatorgroup cert-manager-operator-group \
      -n cert-manager-operator 2>/dev/null || true
    og_count=$(oc get operatorgroup -n cert-manager-operator \
      --no-headers 2>/dev/null | wc -l | xargs)
    if [[ "${og_count:-0}" -gt 1 ]]; then
      oc delete operatorgroup --all -n cert-manager-operator 2>/dev/null || true
      og_count=0
    fi
    ok "OperatorGroup count fixed"
  fi

  info "Discovering latest cert-manager channel..."
  local channel
  channel=$(oc get packagemanifests openshift-cert-manager-operator \
    -n openshift-marketplace \
    -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^stable-v1\.' | sort -t. -k2 -V | tail -1 || echo "")
  [[ -z "$channel" ]] && channel=$(oc get packagemanifests openshift-cert-manager-operator \
    -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null || echo "stable-v1")
  info "  Channel: ${channel}"

  og_count=$(oc get operatorgroup -n cert-manager-operator \
    --no-headers 2>/dev/null | wc -l | xargs)

  if [[ "${og_count:-0}" -gt 0 ]]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  else
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-group
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  fi
}

# Install Service Mesh 2.x — checks both CSV and subscription before applying.
# Skips cleanly if any version of servicemesh is already installed.
install_servicemesh_2() {
  if csv_succeeded_any "servicemesh" openshift-operators; then
    ok "Service Mesh already installed — skipping"
    return 0
  fi
  if subscription_exists_any "servicemesh" openshift-operators; then
    warn "Service Mesh subscription already exists (CSV not yet Succeeded) — skipping re-apply"
    return 0
  fi
  info "Applying Service Mesh 2.x subscription (stable channel)..."
  oc apply -f shared/operators/wave-0/03-servicemesh-subscription.yaml
}

wait_for_csv() {
  local ns="$1" label="$2" timeout="${3:-$WAVE_TIMEOUT}"
  local t=0 phases failed
  echo -n "    Waiting for ${label} to reach Succeeded"
  while true; do
    [[ "$t" -ge "$timeout" ]] && { echo ""; die "Timed out after ${timeout}s waiting for ${label} in ${ns}"; }
    phases=$(oc get csv -n "$ns" -o jsonpath='{.items[*].status.phase}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '^$' || true)
    failed=$(echo "$phases" | grep -v "^Succeeded$" | grep -v '^$' || true)
    if [[ -n "$phases" && -z "$failed" ]]; then echo " OK"; return 0; fi
    echo -n "."
    sleep 20; t=$(( t + 20 ))
  done
}

wait_for_csv_match() {
  local ns="$1" pattern="$2" label="$3" timeout="${4:-$WAVE_TIMEOUT}"
  local t=0 phase
  echo -n "    Waiting for ${label} to reach Succeeded"
  while true; do
    [[ "$t" -ge "$timeout" ]] && { echo ""; die "Timed out after ${timeout}s waiting for ${label} in ${ns}"; }
    phase=$(oc get csv -n "$ns" 2>/dev/null | grep -i "$pattern" | awk '{print $NF}' | head -1 || true)
    if [[ "$phase" == "Succeeded" ]]; then echo " OK"; return 0; fi
    echo -n "."
    sleep 20; t=$(( t + 20 ))
  done
}

wait_for_pod() {
  local ns="$1" selector="$2" label="$3" timeout="${4:-$WB_TIMEOUT}"
  local t=0 ready
  echo -n "    Waiting for ${label} pod to reach Running (2/2)"
  while true; do
    [[ "$t" -ge "$timeout" ]] && { echo ""; die "Timed out after ${timeout}s waiting for ${label} pod in ${ns}"; }
    ready=$(oc get pod -n "$ns" -l "$selector" \
      -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
    # In RHOAI 2.x the notebook pod has 2 containers (notebook + OAuth proxy).
    # Require both to be ready before proceeding.
    if [[ "$ready" == "true true" ]]; then echo " OK"; return 0; fi
    echo -n "."
    sleep 15; t=$(( t + 15 ))
  done
}

# ---------------------------------------------------------------------------
# Step 0 — Sanity checks
# ---------------------------------------------------------------------------
header "Step 0 — Sanity Checks"

command -v oc &>/dev/null      || die "oc CLI not found — install it and add to PATH"
command -v python3 &>/dev/null || die "python3 not found — required for patch-kserve.py"
oc whoami &>/dev/null          || die "Not logged in to OpenShift — run 'oc login' first"
oc auth can-i '*' '*' --all-namespaces &>/dev/null \
                               || die "cluster-admin privileges required"

[[ -f "shared/cluster-admin-setup.sh" ]] \
  || die "Must be run from the repo root: trustyai-telco-demos/"

OCP_VER=$(oc version -o json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("openshiftVersion","unknown"))' \
  2>/dev/null || echo "unknown")

ok "Logged in as $(oc whoami) on OpenShift ${OCP_VER}"
info "RHOAI project : ${RHOAI_PROJECT}"
info "Workbench SA  : ${WORKBENCH_SA}"
info "Demo namespace: ${DEMO_NS}"

# ---------------------------------------------------------------------------
# Step 1 — Wave 0: Foundation operators
# ---------------------------------------------------------------------------
header "Step 1 — Wave 0: Foundation Operators"

info "Applying namespace manifests..."
oc apply -f shared/operators/wave-0/00-namespaces.yaml

apply_if_needed "openshift-nfd" "nfd" "Node Feature Discovery" \
  shared/operators/wave-0/01-nfd-subscription.yaml

install_cert_manager

install_servicemesh_2

apply_if_needed "openshift-serverless" "serverless" "OpenShift Serverless" \
  shared/operators/wave-0/04-serverless-subscription.yaml

GPU_NODES=$(oc get nodes \
  -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null \
  | tr ' ' '\n' | grep -c '[1-9]' || echo "0")
if [[ "${GPU_NODES}" -gt 0 ]]; then
  apply_if_needed "nvidia-gpu-operator" "gpu" "NVIDIA GPU Operator" \
    shared/operators/wave-0/05-gpu-operator-subscription.yaml
else
  warn "No GPU nodes detected — skipping GPU operator (optional)"
fi

# ---------------------------------------------------------------------------
# Step 2 — Wait: Wave 0 CSVs healthy
# ---------------------------------------------------------------------------
header "Step 2 — Wait: Wave 0 Operators Healthy"

wait_for_csv       "openshift-nfd"         "Node Feature Discovery" "$WAVE_TIMEOUT"
wait_for_csv       "cert-manager-operator" "cert-manager"           "$WAVE_TIMEOUT"
wait_for_csv_match "openshift-operators"   "servicemesh"  "Service Mesh 2.x" "$WAVE_TIMEOUT"
wait_for_csv_match "openshift-serverless"  "serverless"   "Serverless"       "$WAVE_TIMEOUT"

ok "Wave 0 — all foundation operators healthy"

# ---------------------------------------------------------------------------
# Step 3 — Wave 1: RHOAI 2.25 + Authorino
# ---------------------------------------------------------------------------
header "Step 3 — Wave 1: RHOAI 2.25 + Authorino"

apply_if_needed "redhat-ods-operator" "rhods"     "RHOAI 2.25" \
  shared/operators/wave-1/01-rhoai-subscription.yaml

apply_if_needed "openshift-operators" "authorino" "Authorino" \
  shared/operators/wave-1/02-authorino-subscription.yaml

# ---------------------------------------------------------------------------
# Step 4 — Wait: Wave 1 CSVs healthy
# ---------------------------------------------------------------------------
header "Step 4 — Wait: Wave 1 Operators Healthy"

wait_for_csv       "redhat-ods-operator" "RHOAI"     "$WAVE_TIMEOUT"
wait_for_csv_match "openshift-operators" "authorino" "Authorino" "$WAVE_TIMEOUT"

ok "Wave 1 — RHOAI 2.25 + Authorino healthy"

# ---------------------------------------------------------------------------
# Step 5 — Post-install: DataScienceCluster + User Workload Monitoring
# ---------------------------------------------------------------------------
header "Step 5 — Post-Install: DataScienceCluster + User Workload Monitoring"

info "Applying DataScienceCluster CR (TrustyAI + KServe RawDeployment + Workbenches)..."
oc apply -f shared/operators/post-install/01-datasciencecluster.yaml

info "Applying user workload monitoring configmap..."
oc apply -f shared/operators/post-install/02-user-workload-monitoring.yaml

# ---------------------------------------------------------------------------
# Step 6 — Wait: DataScienceCluster Ready
# ---------------------------------------------------------------------------
header "Step 6 — Wait: DataScienceCluster Ready"

dsc_t=0
echo -n "    Waiting for DataScienceCluster to reach Ready"
while true; do
  [[ "$dsc_t" -ge "$DSC_TIMEOUT" ]] \
    && { echo ""; die "Timed out after ${DSC_TIMEOUT}s waiting for DataScienceCluster"; }
  dsc_phase=$(oc get datasciencecluster default -n redhat-ods-operator \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$dsc_phase" == "Ready" ]]; then echo " OK"; break; fi
  echo -n "."
  sleep 20; dsc_t=$(( dsc_t + 20 ))
done

ok "DataScienceCluster is Ready — TrustyAI and KServe are active"

# ---------------------------------------------------------------------------
# Step 7 — Create RHOAI Data Science Project
# ---------------------------------------------------------------------------
header "Step 7 — Create RHOAI Data Science Project: ${RHOAI_PROJECT}"

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHOAI_PROJECT}
  annotations:
    openshift.io/display-name: "${RHOAI_PROJECT}"
    openshift.io/description: "TrustyAI Telco Bias Demo — Workbench Project"
  labels:
    kubernetes.io/metadata.name: ${RHOAI_PROJECT}
    opendatahub.io/dashboard: "true"
    modelmesh-enabled: "false"
EOF

ok "Data Science Project '${RHOAI_PROJECT}' created"

# The ServiceAccount must exist before the Notebook CR is applied.
info "Creating workbench ServiceAccount: ${WORKBENCH_SA}..."
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${WORKBENCH_SA}
  namespace: ${RHOAI_PROJECT}
  labels:
    app: ${WORKBENCH_SA}
    opendatahub.io/dashboard: "true"
    opendatahub.io/odh-managed: "true"
EOF
ok "ServiceAccount '${WORKBENCH_SA}' created"

# ---------------------------------------------------------------------------
# Step 8 — Wait for ODH notebook controller mutating webhook
# ---------------------------------------------------------------------------
header "Step 8 — Wait: ODH Notebook Controller Webhook"

# The webhook injects the OAuth proxy sidecar at Notebook creation time.
# Applying the Notebook CR before the webhook is ready means no OAuth proxy,
# no Route, and a workbench pod that cannot be opened from the dashboard.
nb_wh_t=0
nb_wh_timeout=180
echo -n "    Waiting for odh-notebook-controller mutating webhook"
until oc get mutatingwebhookconfiguration odh-notebook-controller-mutating-webhook-configuration \
    &>/dev/null 2>&1; do
  [[ "$nb_wh_t" -ge "$nb_wh_timeout" ]] \
    && die "Timed out waiting for odh-notebook-controller mutating webhook (${nb_wh_timeout}s)"
  echo -n "."
  sleep 10; nb_wh_t=$(( nb_wh_t + 10 ))
done
echo ""
ok "ODH notebook controller webhook ready"

# ---------------------------------------------------------------------------
# Step 9 — Create Workbench (PVC + Notebook CR)
# ---------------------------------------------------------------------------
header "Step 9 — Create Workbench: ${WORKBENCH_SA}"

info "Resolving Standard Data Science notebook image from imagestream..."
NB_TAG=$(oc get is s2i-generic-data-science-notebook -n redhat-ods-applications \
  -o jsonpath='{.status.tags[0].tag}' 2>/dev/null || echo "latest")
NB_IMAGE="image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/s2i-generic-data-science-notebook:${NB_TAG}"
info "  Image: ${NB_IMAGE}"

info "Creating PVC for workbench storage..."
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${WORKBENCH_SA}
  namespace: ${RHOAI_PROJECT}
  labels:
    opendatahub.io/dashboard: "true"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
EOF

info "Creating Notebook CR (workbench)..."
oc apply -f - <<EOF
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: ${WORKBENCH_SA}
  namespace: ${RHOAI_PROJECT}
  annotations:
    notebooks.opendatahub.io/inject-oauth: "true"
    notebooks.opendatahub.io/oauth-logout-url: ""
    opendatahub.io/image-display-name: "Standard Data Science"
    notebooks.opendatahub.io/last-image-selection: "s2i-generic-data-science-notebook:${NB_TAG}"
    notebooks.opendatahub.io/last-size-selection: Small
  labels:
    app: ${WORKBENCH_SA}
    opendatahub.io/dashboard: "true"
    opendatahub.io/odh-managed: "true"
spec:
  template:
    spec:
      affinity: {}
      containers:
        - name: ${WORKBENCH_SA}
          image: "${NB_IMAGE}"
          imagePullPolicy: Always
          env:
            - name: NOTEBOOK_ARGS
              value: |-
                --ServerApp.port=8888
                --ServerApp.token=''
                --ServerApp.password=''
                --ServerApp.base_url=/notebook/${RHOAI_PROJECT}/${WORKBENCH_SA}
                --ServerApp.quit_button=False
            - name: JUPYTER_IMAGE
              value: "${NB_IMAGE}"
          ports:
            - containerPort: 8888
              name: notebook-port
              protocol: TCP
          resources:
            limits:
              cpu: "2"
              memory: 8Gi
            requests:
              cpu: "1"
              memory: 4Gi
          livenessProbe:
            httpGet:
              path: /notebook/${RHOAI_PROJECT}/${WORKBENCH_SA}/api
              port: notebook-port
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
            timeoutSeconds: 1
          readinessProbe:
            httpGet:
              path: /notebook/${RHOAI_PROJECT}/${WORKBENCH_SA}/api
              port: notebook-port
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
            timeoutSeconds: 1
          volumeMounts:
            - mountPath: /opt/app-root/src
              name: ${WORKBENCH_SA}
      enableServiceLinks: false
      serviceAccountName: ${WORKBENCH_SA}
      volumes:
        - name: ${WORKBENCH_SA}
          persistentVolumeClaim:
            claimName: ${WORKBENCH_SA}
EOF

# ---------------------------------------------------------------------------
# Step 10 — Wait: Workbench pod Running (2/2 with OAuth proxy)
# ---------------------------------------------------------------------------
header "Step 10 — Wait: Workbench Pod Running"

wait_for_pod "${RHOAI_PROJECT}" "app=${WORKBENCH_SA}" "${WORKBENCH_SA}" "$WB_TIMEOUT"

if oc get sa "${WORKBENCH_SA}" -n "${RHOAI_PROJECT}" &>/dev/null; then
  ok "Workbench SA '${WORKBENCH_SA}' confirmed in ${RHOAI_PROJECT}"
else
  warn "Workbench SA not yet visible — RBAC step will recheck"
fi

# ---------------------------------------------------------------------------
# Step 11 — RBAC: cluster-admin-setup.sh
# ---------------------------------------------------------------------------
header "Step 11 — RBAC: cluster-admin-setup.sh"

bash shared/cluster-admin-setup.sh

# ---------------------------------------------------------------------------
# Step 12 — Final preflight validation
# ---------------------------------------------------------------------------
header "Step 12 — Preflight Validation"

bash shared/preflight.sh || true

# ---------------------------------------------------------------------------
# Step 13 — KServe CA bundle patch (runs last)
# ---------------------------------------------------------------------------
header "Step 13 — KServe CA Bundle Patch"

# patch-kserve.py does two things permanently:
#   1. Annotates inferenceservice-config with opendatahub.io/managed=false
#      so the RHOAI operator stops reconciling it.
#   2. Adds caBundle/caCertFile so the KServe agent can verify TrustyAI TLS.
python3 shared/patch-kserve.py
ok "KServe inferenceservice-config patched (permanent — RHOAI will not revert)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}  Setup complete. Next steps:${RESET}"
echo ""
echo "  1. Open the RHOAI dashboard."
echo ""
echo "  2. Navigate to:"
echo "     Projects → ${RHOAI_PROJECT} → Workbenches → ${WORKBENCH_SA}"
echo ""
echo "  3. Click 'Open' to launch JupyterLab."
echo ""
echo "  4. Upload the demo notebook:"
echo "     bias-detection/notebooks/trustyai-network-slice-bias-rhoai-2.25.ipynb"
echo ""
echo "  5. Run all cells top to bottom."
echo -e "${BOLD}============================================================${RESET}"
