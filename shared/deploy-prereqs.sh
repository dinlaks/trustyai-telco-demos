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
#   2.  Wave 0 — NFD, cert-manager, Service Mesh, Serverless operator subscriptions
#   3.  Wait  — Wave 0 CSVs reach Succeeded
#   4.  Wave 1 — RHOAI + Authorino subscriptions
#   5.  Wait  — Wave 1 CSVs reach Succeeded
#   6.  Post-install — DataScienceCluster CR + user workload monitoring
#   7.  Wait  — DataScienceCluster reaches Ready
#   8.  Create rhoai-demo Data Science Project
#   9.  Create workbench PVC + Notebook CR (telco-wb)
#   10. Wait  — workbench pod Running (workbench SA is created by the pod)
#   11. RBAC  — cluster-admin-setup.sh (grants, demo namespace)
#   12. Patch — KServe CA bundle (patch-kserve.py)
#   13. Final preflight validation
#
# Prerequisites:
#   - oc CLI installed and logged in as cluster-admin
#   - python3 available (for patch-kserve.py)
#   - Run from the repo root: trustyai-telco-demos/
#
# Override defaults via env vars:
#   RHOAI_PROJECT, WORKBENCH_SA, NAMESPACE, WAVE_TIMEOUT, DSC_TIMEOUT, WB_TIMEOUT
#
# Validated on: OpenShift 4.20 + RHOAI 3.3
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

# Returns true if a CSV matching pattern in namespace is already Succeeded.
csv_succeeded() {
  local ns="$1" pattern="$2"
  local phase
  phase=$(oc get csv -n "$ns" 2>/dev/null | grep -i "$pattern" | awk '{print $NF}' | head -1 || true)
  [[ "$phase" == "Succeeded" ]]
}

# Apply an operator subscription file only if its CSV is not already Succeeded.
# Skipping prevents OperatorGroup conflicts in namespaces pre-populated by the
# cluster provider (e.g. RHDP demo environments).
apply_if_needed() {
  local ns="$1" pattern="$2" label="$3" file="$4"
  if csv_succeeded "$ns" "$pattern"; then
    ok "${label} already installed — skipping"
  else
    info "Applying ${label} subscription..."
    oc apply -f "$file"
  fi
}

# Wait for ALL CSVs in a namespace to reach Succeeded.
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

# Wait for a CSV matching a grep pattern in a namespace.
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

# Wait for a pod label to reach Running.
wait_for_pod() {
  local ns="$1" selector="$2" label="$3" timeout="${4:-$WB_TIMEOUT}"
  local t=0 phase
  echo -n "    Waiting for ${label} pod to reach Running"
  while true; do
    [[ "$t" -ge "$timeout" ]] && { echo ""; die "Timed out after ${timeout}s waiting for ${label} pod in ${ns}"; }
    phase=$(oc get pod -n "$ns" -l "$selector" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Running" ]]; then echo " OK"; return 0; fi
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

apply_if_needed "openshift-nfd"         "nfd"          "Node Feature Discovery" \
  shared/operators/wave-0/01-nfd-subscription.yaml

apply_if_needed "cert-manager-operator" "cert-manager" "cert-manager" \
  shared/operators/wave-0/02-certmanager-subscription.yaml

apply_if_needed "openshift-operators"   "servicemesh"  "OpenShift Service Mesh" \
  shared/operators/wave-0/03-servicemesh-subscription.yaml

apply_if_needed "openshift-serverless"  "serverless"   "OpenShift Serverless" \
  shared/operators/wave-0/04-serverless-subscription.yaml

GPU_NODES=$(oc get nodes \
  -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null \
  | tr ' ' '\n' | grep -c '[1-9]' || echo "0")
if [[ "${GPU_NODES}" -gt 0 ]]; then
  if csv_succeeded "nvidia-gpu-operator" "gpu"; then
    ok "NVIDIA GPU operator already installed — skipping"
  else
    info "GPU nodes detected — applying NVIDIA GPU operator subscription..."
    oc apply -f shared/operators/wave-0/05-gpu-operator-subscription.yaml
  fi
else
  warn "No GPU nodes detected — skipping GPU operator (optional)"
fi

# ---------------------------------------------------------------------------
# Step 2 — Wait: Wave 0 CSVs healthy
# ---------------------------------------------------------------------------
header "Step 2 — Wait: Wave 0 Operators Healthy"

wait_for_csv       "openshift-nfd"         "Node Feature Discovery"    "$WAVE_TIMEOUT"
wait_for_csv       "cert-manager-operator" "cert-manager"              "$WAVE_TIMEOUT"
wait_for_csv_match "openshift-operators"   "servicemesh" "Service Mesh" "$WAVE_TIMEOUT"
wait_for_csv_match "openshift-serverless"  "serverless"  "Serverless"   "$WAVE_TIMEOUT"

ok "Wave 0 — all foundation operators healthy"

# ---------------------------------------------------------------------------
# Step 3 — Wave 1: RHOAI + Authorino
# ---------------------------------------------------------------------------
header "Step 3 — Wave 1: RHOAI + Authorino"

apply_if_needed "redhat-ods-operator" "rhods"     "RHOAI"     \
  shared/operators/wave-1/01-rhoai-subscription.yaml

apply_if_needed "openshift-operators" "authorino" "Authorino" \
  shared/operators/wave-1/02-authorino-subscription.yaml

# ---------------------------------------------------------------------------
# Step 4 — Wait: Wave 1 CSVs healthy
# ---------------------------------------------------------------------------
header "Step 4 — Wait: Wave 1 Operators Healthy"

wait_for_csv       "redhat-ods-operator" "RHOAI"     "$WAVE_TIMEOUT"
wait_for_csv_match "openshift-operators" "authorino" "Authorino" "$WAVE_TIMEOUT"

ok "Wave 1 — RHOAI + Authorino healthy"

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

# ---------------------------------------------------------------------------
# Step 8 — Create Workbench (PVC + Notebook CR)
# ---------------------------------------------------------------------------
header "Step 8 — Create Workbench: ${WORKBENCH_SA}"

# Resolve the latest Standard Data Science notebook image from the RHOAI imagestream.
# Falls back to 'latest' if the imagestream is not yet populated.
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
# Step 9 — Wait: Workbench pod Running
# ---------------------------------------------------------------------------
header "Step 9 — Wait: Workbench Pod Running"

wait_for_pod "${RHOAI_PROJECT}" "app=${WORKBENCH_SA}" "${WORKBENCH_SA}" "$WB_TIMEOUT"

if oc get sa "${WORKBENCH_SA}" -n "${RHOAI_PROJECT}" &>/dev/null; then
  ok "Workbench SA '${WORKBENCH_SA}' confirmed in ${RHOAI_PROJECT}"
else
  warn "Workbench SA not yet visible — RBAC step will recheck"
fi

# ---------------------------------------------------------------------------
# Step 10 — RBAC: cluster-admin-setup.sh
# ---------------------------------------------------------------------------
header "Step 10 — RBAC: cluster-admin-setup.sh"

bash shared/cluster-admin-setup.sh

# ---------------------------------------------------------------------------
# Step 11 — KServe CA bundle patch
# ---------------------------------------------------------------------------
header "Step 11 — KServe CA Bundle Patch"

python3 shared/patch-kserve.py

ok "KServe inferenceservice-config patched"

# ---------------------------------------------------------------------------
# Step 12 — Final preflight validation
# ---------------------------------------------------------------------------
header "Step 12 — Preflight Validation"

bash shared/preflight.sh || true

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
echo "     bias-detection/notebooks/trustyai-network-slice-bias-rhoai-3.3.ipynb"
echo ""
echo "  5. Run all cells top to bottom."
echo -e "${BOLD}============================================================${RESET}"
