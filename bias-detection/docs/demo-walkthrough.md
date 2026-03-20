# Demo Walkthrough — Presenter Guide

## Before You Start

- Complete all steps in [prerequisites.md](prerequisites.md)
- Open the appropriate notebook for your RHOAI version:

| RHOAI Version | Notebook |
|--------------|---------|
| 3.3 (recommended) | `notebooks/trustyai-network-slice-bias-rhoai-3.3.ipynb` |
| 2.25 | `notebooks/trustyai-network-slice-bias-rhoai-2.25.ipynb` |

- Have the OpenShift console open in a second browser tab (Observe → Dashboards)
- Estimated demo runtime: **25–35 minutes** (infrastructure cells run automatically; key narrative moments are at Cells 9, 10, 11, and 12)

---

## Narrative Arc

> *"Every day, this telecom's AI model makes millions of decisions about which customers get premium 5G service. Today we're going to show that it's been silently discriminating against rural customers — and how TrustyAI catches it and fixes it automatically."*

---

## Cell-by-Cell Guide

### Cell 1 — Deploy Infrastructure
**Run time:** ~3 minutes
**What it does:** Deploys MinIO (persistent S3 storage), creates a TLS route, applies the KServe CA bundle patch, and deploys the OVMS ServingRuntime.

**Say to audience:**
> "We're standing up the infrastructure. In a real deployment this would already be in place — MinIO is your model registry, OVMS is your model serving runtime. The important thing to note is that this is all standard OpenShift AI — no special tooling required to get TrustyAI working."

**Watch for:** `✅ Cell 1 complete` in the output. If the CA bundle patch step shows `⚠️`, run `python3 setup/patch-kserve.py` as cluster-admin separately.

---

### Cell 2 — Install Dependencies
**Run time:** ~2 minutes
**What it does:** `pip install` for scikit-learn, ONNX tools, KFP, etc.

**Say to audience:** *(can run silently while talking about the business problem)*
> "While this installs, let me set the scene. This telecom has 15 million subscribers — 20% of whom are rural. Their AI model automatically assigns each customer to a network tier: Basic, Standard, or Premium. The model runs millions of times a day. No human reviews individual decisions. That's what makes this dangerous — and that's what makes monitoring essential."

---

### Cell 3 — Configuration
**Run time:** <5 seconds
**What it does:** Derives cluster domain, builds all endpoint URLs, acquires bearer token.

**Say to audience:** Nothing needed — this is plumbing.

---

### Cell 4 — Generate Dataset
**Run time:** ~5 seconds
**What it does:** Generates 7,000 synthetic customer records. Urban customers get a +0.35 score boost in tier assignment, Rural get -0.25.

**Point to the output table:**
> "Look at this table. Urban customers are assigned Premium tier 54% of the time. Rural customers? Only 13%. This is the training data — and this disparity gets baked directly into the model's decision-making."

| Region | Tier 0 (Basic) | Tier 1 (Standard) | Tier 2 (Premium) |
|--------|---------------|------------------|-----------------|
| Rural | 51.2% | 35.7% | **13.1%** |
| Suburban | 21.8% | 35.7% | 42.5% |
| Urban | 15.7% | 30.3% | **54.1%** |

---

### Cell 5 — Train Model + Export ONNX
**Run time:** ~10 seconds
**What it does:** Trains the MLP classifier, exports to ONNX, strips ZipMap, adds ArgMax + Cast(FP32).

**Say to audience:**
> "The model is a neural network trained on that biased dataset. Its accuracy is decent — around 36% for a 3-class problem that's inherently noisy. But accuracy tells us nothing about fairness. A model can be 'accurate' while systematically discriminating against a protected group."

---

### Cell 6 — Upload Model to MinIO
**Run time:** ~5 seconds

**Say to audience:** *(brief)*
> "Model goes into the registry — MinIO S3. OVMS will pull it from here automatically."

---

### Cell 7 — Deploy TrustyAI + InferenceService + Seed Inferences
**Run time:** ~3–5 minutes
**This is the most important infrastructure cell.**

**Say to audience (while it runs):**
> "This is where TrustyAI comes in. Notice the deployment order — TrustyAI goes up *first*, then the InferenceService. The TrustyAI operator watches for any model with this label:"

```yaml
trustyai.opendatahub.io/monitoring: "true"
```

> "When it sees it, it automatically patches the predictor pod to intercept every single inference. The model developer doesn't change a single line of model code. They just add a label."

**When seeding completes:**
> "We just sent 200 inferences through the model. TrustyAI logged every single one — input features, predicted output, timestamp. That's the audit trail starting."

**Watch for:** `✅ Model registered — observations: [N]` in the output.

---

### Cell 8 — Deploy Prometheus Pushgateway
**Run time:** ~1 minute

**Say to audience:**
> "We're adding a Pushgateway — this is how we get live fairness metrics into Prometheus. The notebook will push computed SPD and DIR values here after each key step, and you'll see them appear in Grafana in real time."

---

### Cell 8b — Grafana Dashboard + Prometheus Monitoring
**Run time:** ~30 seconds

**Switch to the OpenShift console:** Observe → Dashboards → *TrustyAI - Bias Monitor (Network Slice)*

> "Open the Grafana dashboard now. You'll see three panels — inferences monitored, SPD, and DIR. Right now they're empty because we haven't pushed any metrics yet. Watch what happens as we run the next cells."

---

### Cell 9 — Register Monitors + Push Baseline to Grafana
**Run time:** ~10 seconds
**This is the first key narrative moment.**

**Say to audience:**
> "We're registering SPD and DIR monitors with TrustyAI. And now — watch the Grafana dashboard."

**Point to Grafana:**
> "SPD is showing around +0.12. That means Urban customers are getting Premium tier 12 percentage points more often than Rural customers. That's the model's *inherent* bias from training — and it's already borderline. The threshold is ±0.10. We're already slightly outside it just from the training data."

> "DIR is around 0.61. The regulatory threshold is 0.80. We're already below it. This model, as trained, would likely fail a fairness audit. But nobody knew — because before TrustyAI, nobody was measuring."

---

### Cell 10 — Simulate Bias Injection
**Run time:** ~30 seconds
**Second key narrative moment.**

**Say to audience — before running:**
> "Now let's simulate what happens in the real world. Six months pass. The 5G rollout expanded into new rural areas. Customer profiles shifted. The model's predictions start drifting — Rural customers are getting systematically lower charges predicted, Urban customers higher. Let's inject that."

**Run the cell. While it runs:**
> "We're sending 200 skewed inferences through the model via the agent — 100 Urban customers with high charges, 100 Rural with very low charges. This simulates the drift that would happen gradually in production."

---

### Cell 11 — Check SPD/DIR + Alert
**Run time:** ~5 seconds
**Third key narrative moment — the "wow" moment.**

**Run the cell, then point to Grafana:**
> "Look at that. SPD just spiked to +0.60. Rural customers are now 60 percentage points less likely to get Premium than Urban. DIR has dropped to nearly zero."

**Point to the PrometheusRule output:**
> "The PrometheusRule just fired. In a production system, this would page the on-call engineer. The bias wasn't discovered by a customer complaint or a regulator audit — it was caught automatically, in 90 seconds, by TrustyAI."

**The Grafana dashboard now shows the 'biased' series spike clearly.**

---

### Cell 11a — Retrain via KFP Pipeline (if DSPA configured)
**OR**
### Cell 11b — Retrain Locally (no DSPA required)
**Run time:** Cell 11a: ~5 minutes | Cell 11b: ~30 seconds

**Say to audience (Cell 11b for speed):**
> "The fix is retraining. The new training data removes the regional bias — tier assignment is based on what customers actually pay and their income proxy, not on where they live. We're not removing Region from the feature set — the model still sees it. We're removing its *influence on the label*."

**If using Cell 11a (KFP):**
> "Watch the KFP pipeline run in the Data Science Pipelines UI. The pipeline first checks whether bias thresholds are exceeded — yes, they are — then triggers the retraining job. This is the fully automated remediation path. No human intervention required from alert to fix."

**When complete:**
> "The fair model is uploaded to MinIO. The InferenceService will auto-reload it within seconds."

---

### Cell 12 — Verify Fairness Restored
**Run time:** ~30 seconds
**Fourth key narrative moment — the resolution.**

**Run the cell, then point to Grafana:**
> "SPD is back down to around +0.02. DIR is now 0.95. Both metrics are well within threshold. Look at the Grafana dashboard — you can see the complete story: baseline, the bias spike, and now the recovery."

**Point to the journey table in the output:**

```
Metric   Baseline    After Bias    After Retrain   Status
SPD      +0.1157     +0.5800+      +0.0200         ✅
DIR       0.6050      0.0000        0.9500          ✅
```

**Closing line:**
> "Three data points. Three labeled series on a Grafana chart. The complete AI fairness lifecycle — detection, alerting, remediation, verification — in under 30 minutes. And every one of those inference decisions is in an audit log that a regulator can inspect."

---

## Grafana Demo Tips

- The dashboard auto-refreshes every 15 seconds
- The `step` label (`baseline`, `biased`, `fair`) creates distinct colored series — point this out explicitly to the audience
- SPD panel has threshold bands: green zone (fair), yellow zone (warning), red zone (alert)
- DIR panel has a red threshold line at 0.80

**Prometheus queries to show in Observe → Metrics (optional):**

```promql
# Live SPD across all stages
trustyai_spd_live{model="network-slice-model"}

# Live DIR across all stages
trustyai_dir_live{model="network-slice-model"}

# Total inferences TrustyAI has logged
sum(trustyai_model_observations_total{model="network-slice-model"}) by (model)
```

---

## Handling Common Questions

**"What if the model accuracy drops after retraining?"**
> "Good question. The fair model actually has *slightly higher* accuracy — around 39% vs 36%. Removing the geographic bias doesn't hurt predictive performance; it actually improves it by forcing the model to focus on the economically relevant features."

**"Can TrustyAI monitor multiple protected attributes at once?"**
> "Yes — you register separate SPD/DIR monitors for each protected attribute. In a production deployment you might monitor Region, Income, and even combinations of the two."

**"What does TrustyAI do beyond SPD and DIR?"**
> "TrustyAI also provides explainability — LIME and SHAP for individual prediction explanations, counterfactuals, and data drift detection. This demo focuses on the group fairness monitoring story but the toolkit goes much deeper."

**"Is this GDPR/EU AI Act compliant?"**
> "The EU AI Act requires documentation that monitoring was in place. TrustyAI's audit trail — every inference logged, every metric computed — provides exactly that documentation. The PrometheusRule alerts with timestamps give you evidence of active monitoring."

**"What happens to the old model after retraining?"**
> "The InferenceService auto-reloads the new model from MinIO when the file changes. In production you'd version the model — the old ONNX file would be archived in the S3 bucket, the new one becomes the active model. KServe handles the hot-reload with zero downtime."

---

## Reset Between Demo Runs

To reset the namespace and start fresh:

```bash
oc delete namespace telco-bias-demo
# Wait ~30 seconds, then re-run from Cell 1
```

The workbench itself doesn't need to be restarted. Re-run Cell 3 (Configuration) first after a namespace reset.
