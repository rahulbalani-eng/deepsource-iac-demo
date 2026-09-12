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
          issues(first: 50) {
            edges {
              node {
                title
                path
                severity
                shortcode
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
repo = data.get("data", {}).get("repository")
if not repo:
    print("No repository data returned. Check DEEPSOURCE_REPO/LOGIN/VCS and that the repo is activated.")
    print(json.dumps(data, indent=2))
    sys.exit(0)

name = repo.get("name")
activated = repo.get("isActivated")
runs = repo.get("latestAnalysisRun", {}).get("edges", [])
if not runs:
    print("Repository %r activated=%r but no analysis runs yet." % (name, activated))
    sys.exit(0)

run = runs[0]["node"]
commit = (run.get("commitOid") or "")[:8]
print("Repository: %s  |  Run status: %s  |  Commit: %s" % (name, run.get("status"), commit))
print("-" * 56)

issues = run.get("issues", {}).get("edges", [])
if not issues:
    print("No issues found on this run.")
else:
    for edge in issues:
        node = edge["node"]
        print("[%8s] %-12s %s" % (node.get("severity"), node.get("shortcode"), node.get("path")))
        print("           %s" % node.get("title"))
    print("-" * 56)
    print("Total issues: %s" % len(issues))
'
echo "======================================================="
