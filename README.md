# DeepSource → IaCM pipeline demo

Goal: run DeepSource's static analysis against a Terraform module as a real
step inside a Harness IACM pipeline, right after clone and before `plan`,
with the findings printed straight into the step logs.

This folder is intentionally kept **outside** `iac-server` — `main.tf` here
has deliberate misconfigurations for DeepSource to catch, and mixing that
into the actual product repo would trip its own gitleaks/hadolint/Sonar
gates for no reason.

## What's in here

- `main.tf` / `variables.tf` — a small Terraform module with 5 deliberate
  issues: world-open security group, public S3 ACL with no
  encryption/versioning, an `Action:*`/`Resource:*` IAM policy, an
  unencrypted+publicly-accessible+hardcoded-password RDS instance, and an
  unused variable (lint noise).
- `deepsource-scan.sh` — calls the DeepSource GraphQL API for the repo's
  latest analysis run and pretty-prints the issues. This is what the
  pipeline step runs.
- `harness-pipeline.yaml` — an IACM pipeline: clone (implicit) → **DeepSource
  Scan** (new `Run` step) → `init` → `plan`.

## Setup (10-15 min)

1. **Push this folder to a new *public* GitHub repo** named
   `deepsource-iac-demo` (public is required for DeepSource's free Open
   Source plan — see pricing notes below).

   ```bash
   cd ~/Desktop/deepsource-iac-demo
   git init && git add -A && git commit -m "DeepSource IaC demo"
   gh repo create deepsource-iac-demo --public --source=. --push
   ```

2. **Connect the repo to DeepSource** (free, no card needed):
   - Sign up at https://deepsource.com with GitHub, select the
     **Open Source** plan.
   - Activate analysis on `deepsource-iac-demo`.
   - Wait for the first analysis run to finish (~30s) — confirms DeepSource
     can actually see the Terraform issues in `main.tf`.
   - Create a **Personal Access Token**: DeepSource dashboard → account
     settings → API tokens.

3. **Store the PAT as a Harness secret**:
   - In your Harness account/org/project, create a secret named
     `deepsource_pat` with the token value.
   - The pipeline YAML references it as
     `<+secrets.getValue("deepsource_pat")>`.

4. **Create an IaCM workspace** pointing at `deepsource-iac-demo` (any
   provisioner — Terraform), following the normal IaCM workspace setup.

5. **Import `harness-pipeline.yaml`** into that project (Pipelines → Create
   → Import from YAML), fill in `orgIdentifier`/`projectIdentifier`/
   `workspace`, and set `DEEPSOURCE_LOGIN` to your GitHub username/org.

6. **Run the pipeline.** The "DeepSource Scan" step log will print each
   issue (severity, rule shortcode, file, title) before `init`/`plan` even
   run — that's the live demo. `deepsource_findings.json` is also written to
   the step's workspace if you want to show the raw payload or feed it into
   something else (e.g. mocking the Insights tab from the earlier plan).

## Free tier notes

- **Open Source plan** (what this demo uses): free forever, but **public
  repos only** — 1,000 analysis runs/month, full static analysis/SAST/IaC
  rules, secrets detection is Team-only.
- If you need a **private** repo instead, DeepSource's **Team plan has a
  14-day free trial, no credit card required** (up to $50 in bundled AI
  Review credits) — same setup steps, just skip step 1's `--public` flag.

## Extending the demo

- Swap the `Run` step's script for `terraform validate`-style exit-code
  gating (fail the step / block `plan` if severity ≥ Critical) to show
  policy enforcement, not just visibility.
- Point step 6's output at a GitOps PR comment instead of just logs, to
  mirror the existing CCM cost PR-comment pattern described in the IaCM ×
  CCM integration spec.
