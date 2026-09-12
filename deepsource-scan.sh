#!/usr/bin/env bash
# Queries the DeepSource GraphQL API for the latest analysis run on this
# repo's default branch and pretty-prints the issues found, so the output
# shows up directly in the Harness pipeline step logs.
#
# Required env vars (set as pipeline/stage variables backed by Harness secrets):
#   DEEPSOURCE_TOKEN   - Personal Access Token from DeepSource
#   DEEPSOURCE_REPO    - repo name as known to DeepSource, e.g. "deepsource-iac-demo"
#   DEEPSOURCE_LOGIN   - your GitHub org/user login, e.g. "rahulbalani"
#   DEEPSOURCE_VCS     - GITHUB | GITLAB | BITBUCKET (defaults to GITHUB)

set -euo pipefail

DEEPSOURCE_VCS="${DEEPSOURCE_VCS:-GITHUB}"

if [[ -z "${DEEPSOURCE_TOKEN:-}" || -z "${DEEPSOURCE_REPO:-}" || -z "${DEEPSOURCE_LOGIN:-}" ]]; then
  echo "Missing DEEPSOURCE_TOKEN / DEEPSOURCE_REPO / DEEPSOURCE_LOGIN" >&2
  exit 1
fi

QUERY=$(cat <<EOF
query {
  repository(name: "${DEEPSOURCE_REPO}", login: "${DEEPSOURCE_LOGIN}", vcsProvider: ${DEEPSOURCE_VCS}) {
    name
    isActivated
    latestAnalysisRun: analysisRuns(first: 1) {
      edges {
        node {
          status
          commitOid
        }
      }
    }
    issues(first: 50) {
      edges {
        node {
          issue {
            title
            shortcode
            severity
          }
          occurrences(first: 5) {
            edges {
              node {
                path
              }
            }
          }
        }
      }
    }
  }
}
EOF
)

# Escape the query for JSON embedding.
ESCAPED_QUERY=$(printf '%s' "$QUERY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

RESPONSE=$(curl -sS "https://api.deepsource.com/graphql/" \
  -X POST \
  -H "Authorization: Bearer ${DEEPSOURCE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"query\": ${ESCAPED_QUERY}}")

echo "$RESPONSE" > deepsource_findings.json

echo ""
echo "================ DeepSource Findings ================"
echo "$RESPONSE" | python3 -c '
import json, sys

data = json.load(sys.stdin)
if data.get("errors"):
    print("GraphQL errors:")
    print(json.dumps(data["errors"], indent=2))

repo = (data.get("data") or {}).get("repository")
if not repo:
    print("No repository data returned. Check DEEPSOURCE_REPO/LOGIN/VCS and that the repo is activated.")
    print(json.dumps(data, indent=2))
    sys.exit(0)

name = repo.get("name")
activated = repo.get("isActivated")
runs = (repo.get("latestAnalysisRun") or {}).get("edges") or []
if runs:
    run = runs[0]["node"]
    commit = (run.get("commitOid") or "")[:8]
    print("Repository: %s  |  activated=%s  |  Run status: %s  |  Commit: %s" % (
        name, activated, run.get("status"), commit))
else:
    print("Repository: %s  |  activated=%s  |  no analysis runs yet" % (name, activated))
print("-" * 56)

issues = (repo.get("issues") or {}).get("edges") or []
if not issues:
    print("No issues found on the default branch.")
else:
    total = 0
    for edge in issues:
        node = edge.get("node") or {}
        issue = node.get("issue") or {}
        occs = ((node.get("occurrences") or {}).get("edges") or [])
        paths = []
        for occ in occs:
            path = ((occ.get("node") or {}).get("path"))
            if path:
                paths.append(path)
        path_str = ", ".join(paths) if paths else "(no path)"
        print("[%s] %s  %s" % (issue.get("severity"), issue.get("shortcode"), path_str))
        print("           %s" % issue.get("title"))
        total += 1
    print("-" * 56)
    print("Total issues: %s" % total)
'
echo "======================================================="

# Convert GraphQL issues into the Insights ingest payload and POST them.
# Plan success is not required. Missing IACM endpoint/token skips ingest
# without failing the step (so Init/Plan can still run).
python3 - <<'PY'
import json, os, sys

raw = open("deepsource_findings.json").read()
data = json.loads(raw)
repo = (data.get("data") or {}).get("repository") or {}
findings = []
for edge in ((repo.get("issues") or {}).get("edges") or []):
    node = edge.get("node") or {}
    issue = node.get("issue") or {}
    occs = ((node.get("occurrences") or {}).get("edges") or [])
    paths = []
    for occ in occs:
        path = ((occ.get("node") or {}).get("path"))
        if path:
            paths.append(path)
    shortcode = issue.get("shortcode") or ""
    title = issue.get("title") or ""
    if not shortcode or not title:
        continue
    findings.append({
        "title": title,
        "severity": issue.get("severity") or "",
        "shortcode": shortcode,
        "path": ", ".join(paths),
        "details_link": os.environ.get("DEEPSOURCE_DETAILS_LINK", ""),
    })
open("ingest_findings.json", "w").write(json.dumps({"findings": findings}))
print("Prepared %d finding(s) for Insights ingest." % len(findings))
PY

ingest_insights() {
  local endpoint token account org project workspace
  if [[ -n "${PLUGIN_ENDPOINT_VARIABLES:-}" ]]; then
    eval "$(python3 - <<'PY'
import json, os, shlex
raw = os.environ.get("PLUGIN_ENDPOINT_VARIABLES") or "{}"
try:
    d = json.loads(raw)
except Exception:
    d = {}
for k, env in (
    ("base_url", "IACM_BASE_URL"),
    ("token", "IACM_TOKEN"),
    ("account_id", "IACM_ACCOUNT"),
    ("org_id", "IACM_ORG"),
    ("project_id", "IACM_PROJECT"),
    ("workspace_id", "IACM_WORKSPACE"),
):
    v = d.get(k) or ""
    print("export %s=%s" % (env, shlex.quote(str(v))))
PY
)"
  fi

  endpoint="${HARNESS_IACM_SERVICE_ENDPOINT:-${IACM_BASE_URL:-}}"
  token="${HARNESS_IACM_SERVICE_TOKEN:-${IACM_TOKEN:-}}"
  account="${HARNESS_ACCOUNT_ID:-${IACM_ACCOUNT:-}}"
  org="${HARNESS_ORG_ID:-${IACM_ORG:-default}}"
  project="${HARNESS_PROJECT_ID:-${IACM_PROJECT:-test}}"
  workspace="${PLUGIN_WORKSPACE:-${IACM_WORKSPACE:-}}"

  if [[ -z "$endpoint" || -z "$token" || -z "$account" || -z "$workspace" ]]; then
    echo "Skipping Insights ingest: need IACM endpoint, token, account, and workspace."
    echo "Set PLUGIN_ENDPOINT_VARIABLES (IACM plugin env) or HARNESS_IACM_SERVICE_ENDPOINT / HARNESS_IACM_SERVICE_TOKEN / PLUGIN_WORKSPACE."
    return 0
  fi

  endpoint="${endpoint%/}"
  echo "Ingesting findings into ${endpoint}/api/orgs/${org}/projects/${project}/workspaces/${workspace}/insights/security"
  curl -sS -o ingest_response.txt -w "Insights ingest HTTP %{http_code}\n" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${token}" \
    -H "Harness-Account: ${account}" \
    --data @ingest_findings.json \
    "${endpoint}/api/orgs/${org}/projects/${project}/workspaces/${workspace}/insights/security" || true
  if [[ -s ingest_response.txt ]]; then
    cat ingest_response.txt
    echo
  fi
}

ingest_insights
