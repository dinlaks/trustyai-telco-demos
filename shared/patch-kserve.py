"""
patch-kserve.py — Configures inferenceservice-config for TrustyAI TLS.

Steps (from odh-trustyai-demos 1-Installation/README.md):
  1. Annotate inferenceservice-config with opendatahub.io/managed=false
     so the RHOAI operator stops reconciling it and the patch is permanent.
  2. Patch the logger section to add caBundle/caCertFile pointing to
     kserve-logger-ca-bundle so the KServe agent can verify TrustyAI TLS.
"""
import subprocess, json, sys

NS = "redhat-ods-applications"
CM = "inferenceservice-config"

def run(cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"ERROR: {' '.join(cmd)}\n{r.stderr}", file=sys.stderr)
        sys.exit(1)
    return r

# Step 1: Mark inferenceservice-config as unmanaged so RHOAI stops reconciling it
print("Step 1: Marking inferenceservice-config as unmanaged by RHOAI operator...")
run(["oc", "patch", "configmap", CM, "-n", NS,
     "--type", "merge",
     "-p", '{"metadata": {"annotations": {"opendatahub.io/managed": "false"}}}'])
print("  ✅  opendatahub.io/managed=false set")

# Step 2: Patch the logger section with caBundle
print("Step 2: Patching logger with caBundle...")
r = run(["oc", "get", "configmap", CM, "-n", NS,
         "-o", "jsonpath={.data.logger}"])
current = json.loads(r.stdout) if r.stdout.strip() else {}

updated = {
    **current,
    "caBundle":      "kserve-logger-ca-bundle",
    "caCertFile":    "service-ca.crt",
    "tlsSkipVerify": False,
}

patch = json.dumps([{
    "op": "add", "path": "/data/logger",
    "value": json.dumps(updated)
}])
run(["oc", "patch", "configmap", CM, "-n", NS, "--type", "json", "-p", patch])

# Verify
r = run(["oc", "get", "configmap", CM, "-n", NS, "-o", "jsonpath={.data.logger}"])
if "caBundle" in r.stdout:
    print("  ✅  inferenceservice-config patched with caBundle (permanent — RHOAI will not revert)")
else:
    print("  ⚠️   caBundle not found after patch")
    sys.exit(1)
