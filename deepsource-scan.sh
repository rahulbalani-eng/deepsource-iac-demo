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
