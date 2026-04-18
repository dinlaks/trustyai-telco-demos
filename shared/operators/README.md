# Operator Pre-Requisites — RHOAI 2.25

> **Prefer the automated path?** `bash shared/deploy-prereqs.sh` runs all of the steps below end-to-end — operators, DataScienceCluster, workbench creation, RBAC, and KServe patch — with health checks between each wave. Use this manual guide when you need per-step control or to troubleshoot a specific wave.

Apply these manifests **once per cluster** before running any demo notebook.
All steps require `cluster-admin` privileges.

---

## Step 0 — OpenShift Cluster

**A running OpenShift 4.18+ cluster is required before proceeding.**

Verify your cluster version and admin access:

```bash
oc version
oc whoami
# Expected: cluster-admin or kubeadmin
```

Confirm the cluster is healthy:

```bash
oc get nodes
oc get clusteroperators | grep -v "True.*False.*False"
# All operators should show: Available=True, Progressing=False, Degraded=False
```

---

## Operator Install Order

Operators must be applied in wave order. Each wave must be fully healthy before starting the next.

```
Wave 0  →  Wave 1  →  Post-Install
```

---

## Wave 0 — Foundation Operators (install first)

These must be running before RHOAI can be installed.

```bash
# 1. Create all required namespaces
oc apply -f shared/operators/wave-0/00-namespaces.yaml

# 2. Node Feature Discovery — hardware labeling
oc apply -f shared/operators/wave-0/01-nfd-subscription.yaml

# 3. cert-manager — TLS certificate automation
oc apply -f shared/operators/wave-0/02-certmanager-subscription.yaml

# 4. OpenShift Service Mesh 2.x — operator dependency for RHOAI 2.25
oc apply -f shared/operators/wave-0/03-servicemesh-subscription.yaml

# 5. OpenShift Serverless — operator dependency for RHOAI
oc apply -f shared/operators/wave-0/04-serverless-subscription.yaml

# 6. NVIDIA GPU Operator — skip if no GPU nodes
oc apply -f shared/operators/wave-0/05-gpu-operator-subscription.yaml
```

Wait for Wave 0 to be healthy:

```bash
oc get csv -n openshift-nfd
oc get csv -n cert-manager-operator
oc get csv -n openshift-operators | grep -E "servicemesh|serverless"
# All should show PHASE: Succeeded
```

---

## Wave 1 — RHOAI Platform

```bash
# 1. Red Hat OpenShift AI
oc apply -f shared/operators/wave-1/01-rhoai-subscription.yaml

# 2. Authorino — KServe model endpoint authentication
oc apply -f shared/operators/wave-1/02-authorino-subscription.yaml
```

Wait for RHOAI operator to be healthy:

```bash
oc get csv -n redhat-ods-operator
# Should show: rhods-operator.<version>   Succeeded

oc get pods -n redhat-ods-operator
# Should show the operator pod Running
```

---

## Post-Install — Activate RHOAI Components

```bash
# 1. DataScienceCluster — enables TrustyAI, KServe (RawDeployment), Workbenches
oc apply -f shared/operators/post-install/01-datasciencecluster.yaml

# 2. User Workload Monitoring — enables Prometheus scraping in demo namespaces
oc apply -f shared/operators/post-install/02-user-workload-monitoring.yaml
```

Wait for RHOAI components to deploy:

```bash
oc get pods -n redhat-ods-applications
# TrustyAI, KServe, dashboard pods should all reach Running state

oc get datasciencecluster default -n redhat-ods-operator -o jsonpath='{.status.phase}'
# Expected: Ready
```

---

## Next Step

Once all operators are healthy, run the cluster-admin RBAC setup:

```bash
bash shared/cluster-admin-setup.sh
```

Then proceed to the demo notebook in `bias-detection/notebooks/`.

---

## Component Summary

| Operator | Namespace | Wave | Required |
|----------|-----------|------|----------|
| Node Feature Discovery | `openshift-nfd` | 0 | Yes |
| cert-manager | `cert-manager-operator` | 0 | Yes |
| OpenShift Service Mesh 2.x | `openshift-operators` | 0 | Yes (RHOAI dependency) |
| OpenShift Serverless | `openshift-serverless` | 0 | Yes (RHOAI dependency) |
| NVIDIA GPU Operator | `nvidia-gpu-operator` | 0 | Optional |
| Red Hat OpenShift AI 2.25 | `redhat-ods-operator` | 1 | Yes |
| Authorino | `openshift-operators` | 1 | Yes |
| DataScienceCluster CR | `redhat-ods-operator` | post | Yes |
| User Workload Monitoring | `openshift-monitoring` | post | Yes |
