#!/usr/bin/env bash
# teardown.sh — Removes all TrustyAI demo resources from the cluster.
# Removes demo workloads only — does NOT remove RHOAI, operators, or the
# rhoai-demo project/workbench.
#
# Usage: bash shared/teardown.sh --confirm

set -euo pipefail

NAMESPACE="${NAMESPACE:-telco-bias-demo}"
RHOAI_PROJECT="${RHOAI_PROJECT:-rhoai-demo}"
GRAFANA_NAMESPACE="openshift-config-managed"
GRAFANA_DASHBOARD_UID="trustyai-bias-005"

# ---------------------------------------------------------------------------
# Safety gate
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--confirm" ]]; then
  echo ""
  echo "TrustyAI Demo Teardown"
  echo "======================"
  echo ""
  echo "This will delete the following resources:"
  echo "  - Namespace: $NAMESPACE (TrustyAI, KServe ISVC, MinIO, Pushgateway, all demo workloads)"
  echo "  - Grafana dashboard ConfigMap '$GRAFANA_DASHBOARD_UID' from $GRAFANA_NAMESPACE"
  echo "  - RBAC grants for $RHOAI_PROJECT:$WORKBENCH_SA (cluster-level roles)"
  echo ""
  echo "This will NOT delete:"
  echo "  - RHOAI operator or DataScienceCluster"
  echo "  - The '$RHOAI_PROJECT' project or workbench"
  echo "  - Any cluster-level operators (NFD, cert-manager, OSSM, Serverless, GPU)"
  echo ""
  echo "Re-run with --confirm to proceed:"
  echo "  bash shared/teardown.sh --confirm"
  echo ""
  exit 0
fi

WORKBENCH_SA="${WORKBENCH_SA:-telco-wb}"

echo ""
echo "Starting teardown of TrustyAI demo resources..."
echo ""

# ---------------------------------------------------------------------------
# 1. Delete demo namespace (removes everything inside it)
# ---------------------------------------------------------------------------
echo "--> Deleting namespace: $NAMESPACE"
if oc get namespace "$NAMESPACE" &>/dev/null; then
  oc delete namespace "$NAMESPACE" --wait=true
  echo "    Namespace $NAMESPACE deleted."
else
  echo "    Namespace $NAMESPACE not found — skipping."
fi

# ---------------------------------------------------------------------------
# 2. Remove Grafana dashboard ConfigMap
# ---------------------------------------------------------------------------
echo "--> Removing Grafana dashboard from $GRAFANA_NAMESPACE"
if oc get configmap "trustyai-bias-dashboard" -n "$GRAFANA_NAMESPACE" &>/dev/null; then
  oc delete configmap "trustyai-bias-dashboard" -n "$GRAFANA_NAMESPACE"
  echo "    Grafana dashboard ConfigMap deleted."
else
  echo "    Grafana dashboard ConfigMap not found — skipping."
fi

# ---------------------------------------------------------------------------
# 3. Remove cluster-level RBAC grants for workbench SA
# ---------------------------------------------------------------------------
SA="system:serviceaccount:${RHOAI_PROJECT}:${WORKBENCH_SA}"
echo "--> Removing cluster-level RBAC grants for $SA"

oc adm policy remove-cluster-role-from-user self-provisioner "$SA" 2>/dev/null \
  && echo "    Removed self-provisioner" \
  || echo "    self-provisioner not present — skipping"

oc adm policy remove-cluster-role-from-user cluster-reader "$SA" 2>/dev/null \
  && echo "    Removed cluster-reader" \
  || echo "    cluster-reader not present — skipping"

# ---------------------------------------------------------------------------
# 4. Remove namespace-scoped RBAC from openshift-config-managed
# ---------------------------------------------------------------------------
echo "--> Removing admin role from $GRAFANA_NAMESPACE for $SA"
oc adm policy remove-role-from-user admin "$SA" -n "$GRAFANA_NAMESPACE" 2>/dev/null \
  && echo "    Removed admin from $GRAFANA_NAMESPACE" \
  || echo "    Not present — skipping"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Teardown complete."
echo ""
echo "To re-run the demo, execute:"
echo "  bash shared/cluster-admin-setup.sh"
echo "  python3 shared/patch-kserve.py"
echo "Then re-run the notebook from Cell 1."
echo ""
