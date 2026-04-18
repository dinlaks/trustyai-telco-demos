#!/usr/bin/env bash
# =============================================================================
# cluster-admin-setup.sh
# Run ONCE as cluster-admin before executing the demo notebook.
# Safe to re-run if the namespace is recreated.
#
# Prerequisites:
#   - oc CLI installed and logged in as cluster-admin
#   - RHOAI 2.x or 3.x installed on the cluster
#   - Workbench named 'telco-wb' created in project 'rhoai-demo'
#
# Validated on: OpenShift 4.20 + RHOAI 2.25 / 3.3
# =============================================================================

set -euo pipefail

WB_PROJECT="rhoai-demo"
WB_NAME="telco-wb"
DEMO_NS="telco-bias-demo"
WB_SA="system:serviceaccount:${WB_PROJECT}:${WB_NAME}"

echo "======================================================================"
echo "  TrustyAI Telco Bias Demo — Cluster-Admin Setup"
echo "  Workbench SA : ${WB_SA}"
echo "  Demo namespace: ${DEMO_NS}"
echo "======================================================================"
echo ""

# Verify cluster-admin access
echo "[1/6] Verifying cluster-admin access..."
oc auth can-i '*' '*' --all-namespaces > /dev/null 2>&1 || {
  echo "ERROR: This script must be run as cluster-admin."
  exit 1
}
echo "  OK — cluster-admin confirmed"
echo ""

# Step 1: Allow workbench SA to create new projects
echo "[2/6] Granting self-provisioner to workbench SA..."
oc adm policy add-cluster-role-to-user self-provisioner "${WB_SA}"
echo "  OK"
echo ""

# Step 2: Allow workbench SA to read cluster-wide resources
echo "[3/6] Granting cluster-reader to workbench SA..."
oc adm policy add-cluster-role-to-user cluster-reader "${WB_SA}"
echo "  OK"
echo ""

# Step 3: Create the demo namespace
echo "[4/6] Creating demo namespace: ${DEMO_NS}..."
oc new-project "${DEMO_NS}" 2>/dev/null || echo "  Namespace already exists — skipping"
echo "  OK"
echo ""

# Step 4: Grant admin on demo namespace
echo "[5/6] Granting admin on ${DEMO_NS} to workbench SA..."
oc adm policy add-role-to-user admin "${WB_SA}" -n "${DEMO_NS}"
echo "  OK"
echo ""

# Step 5: Grant monitoring-edit on demo namespace
#   Required for Cell 8 — creates ServiceMonitors and PrometheusRules
echo "[6/6a] Granting monitoring-edit on ${DEMO_NS} to workbench SA..."
oc adm policy add-role-to-user monitoring-edit "${WB_SA}" -n "${DEMO_NS}"
echo "  OK"
echo ""

# Step 6: Grant admin on openshift-config-managed
#   Required for Cell 8b — applies Grafana dashboard ConfigMap
echo "[6/6b] Granting admin on openshift-config-managed to workbench SA..."
oc adm policy add-role-to-user admin "${WB_SA}" -n openshift-config-managed
echo "  OK"
echo ""

# Step 7: Grant workbench SA rights to pause RHOAI operator + patch inferenceservice-config
#   RHOAI 2.25.4 reconciles inferenceservice-config immediately when changed, removing
#   the caBundle field needed for TrustyAI TLS. Cell 7 briefly scales the RHOAI operator
#   to 0 replicas, patches the configmap, creates the ISVC (so the KServe webhook reads
#   the patched config at pod admission), then restores the operator.
echo "[7/7] Granting RHOAI pause + inferenceservice-config patch rights..."
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${WB_NAME}-rhoai-ops
  namespace: redhat-ods-operator
rules:
- apiGroups: ["apps"]
  resources: ["deployments","deployments/scale"]
  resourceNames: ["rhods-operator"]
  verbs: ["get","patch","update"]
EOF
oc create rolebinding "${WB_NAME}-rhoai-ops" \
  --role="${WB_NAME}-rhoai-ops" \
  --serviceaccount="${WB_PROJECT}:${WB_NAME}" \
  -n redhat-ods-operator 2>/dev/null \
  || oc patch rolebinding "${WB_NAME}-rhoai-ops" -n redhat-ods-operator \
       --type=merge -p "{\"subjects\":[{\"kind\":\"ServiceAccount\",\"name\":\"${WB_NAME}\",\"namespace\":\"${WB_PROJECT}\"}]}"
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${WB_NAME}-kserve-config
  namespace: redhat-ods-applications
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["inferenceservice-config"]
  verbs: ["get","patch","update"]
EOF
oc create rolebinding "${WB_NAME}-kserve-config" \
  --role="${WB_NAME}-kserve-config" \
  --serviceaccount="${WB_PROJECT}:${WB_NAME}" \
  -n redhat-ods-applications 2>/dev/null \
  || oc patch rolebinding "${WB_NAME}-kserve-config" -n redhat-ods-applications \
       --type=merge -p "{\"subjects\":[{\"kind\":\"ServiceAccount\",\"name\":\"${WB_NAME}\",\"namespace\":\"${WB_PROJECT}\"}]}"
echo "  OK"
echo ""

# Verification
echo "======================================================================"
echo "  Verification"
echo "======================================================================"
echo ""
echo "Cluster-wide role bindings for ${WB_NAME}:"
oc get clusterrolebinding | grep "${WB_NAME}" || echo "  (none found — check if workbench name is correct)"
echo ""
echo "Namespace role bindings in ${DEMO_NS}:"
oc get rolebinding -n "${DEMO_NS}" | grep "${WB_NAME}" || echo "  (none found)"
echo ""
echo "Namespace role binding in openshift-config-managed:"
oc get rolebinding -n openshift-config-managed | grep "${WB_NAME}" || echo "  (none found)"
echo ""

echo "======================================================================"
echo "  NEXT STEP: Apply the KServe CA bundle patch"
echo ""
echo "  python3 shared/patch-kserve.py"
echo ""
echo "  This patches inferenceservice-config in redhat-ods-applications"
echo "  so the KServe agent can verify TrustyAI's TLS certificate."
echo "======================================================================"
