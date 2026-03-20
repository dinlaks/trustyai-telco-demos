import subprocess, json

SHA = "a53d941f6b3720302dd8309a3eba59b0873931df5e274b9051930563df6c750d"
IMAGE = "registry.redhat.io/rhoai/odh-kserve-agent-rhel9@sha256:" + SHA
NS = "redhat-ods-applications"

logger_val = json.dumps({
    "image": IMAGE,
    "memoryRequest": "100Mi",
    "memoryLimit": "1Gi",
    "cpuRequest": "100m",
    "cpuLimit": "1",
    "defaultUrl": "http://default-broker",
    "caBundle": "kserve-logger-ca-bundle",
    "caCertFile": "service-ca.crt",
    "tlsSkipVerify": False
})

patch = json.dumps([{"op": "add", "path": "/data/logger", "value": logger_val}])

r = subprocess.run(
    ["oc", "patch", "configmap", "inferenceservice-config",
     "-n", NS, "--type", "json", "-p", patch],
    capture_output=True, text=True)
print(r.stdout or r.stderr)
