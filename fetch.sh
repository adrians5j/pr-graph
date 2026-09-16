#!/usr/bin/env bash
# Pulls merged PRs from GitHub and writes data.js next to index.html.
# Output is a .js file (not .json) so index.html works when opened from file://.
set -euo pipefail

REPO="${PR_GRAPH_REPO:-webiny/webiny-js}"
DAYS="${PR_GRAPH_DAYS:-90}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# BSD date locally, GNU date on CI runners.
days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d; }
SINCE="$(days_ago "$DAYS")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Fetching PRs merged into $REPO since $SINCE ..." >&2

gh pr list \
  --repo "$REPO" \
  --state merged \
  --search "merged:>=$SINCE" \
  --limit 1000 \
  --json number,title,baseRefName,headRefName,mergedAt,author,url,additions,deletions,changedFiles \
  | jq -c --arg repo "$REPO" --arg since "$SINCE" --arg now "$NOW" \
      '{repo:$repo, since:$since, fetchedAt:$now, prs:.}' \
  | { printf 'window.PR_DATA = '; cat; printf ';\n'; } \
  > "$DIR/data.js"

echo "Wrote $DIR/data.js ($(jq -r '.prs|length' <(sed -e 's/^window.PR_DATA = //' -e 's/;$//' "$DIR/data.js")) PRs)" >&2
