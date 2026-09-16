#!/usr/bin/env bash
# Groups the fetched PRs into work streams and writes summary.js.
# Uses the `claude` CLI, so there is no API key to configure.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${PR_GRAPH_MODEL:-claude-sonnet-5}"
WINDOWS="${PR_GRAPH_WINDOWS:-14 30 90}"
# BSD date locally, GNU date on CI runners.
days_ago() { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$DIR/data.js" ] || { echo "No data.js. Run ./fetch.sh first." >&2; exit 1; }
sed -e 's/^window.PR_DATA = //' -e 's/;$//' "$DIR/data.js" > "$TMP/data.json"

read -r -d '' BRIEF <<'P' || true
You are summarizing merged pull requests for a release manager who has been away
and wants to know what actually landed.

Below is every PR merged into the repository's mainline (`next`) and its release
branches, one per line, tab separated: number, target branch, merge date, title.

Group them into 4 to 8 work streams. A work stream is a coherent piece of work,
not a category: several PRs that together move one thing forward belong in one
stream, even when their commit scopes differ. Order the streams by how much a
person on this team would care, most significant first.

Rules:
- Every PR number must appear in exactly one stream.
- `title` is at most 6 words, names the actual thing, no filler like "various" or "improvements".
- `summary` is ONE sentence saying what changed and what it means for someone using or maintaining this. No hype, no restating the title.
- `kind` is "user" if someone using the product would notice, otherwise "internal".
- Put genuine one-offs in a final stream titled "Everything else".

Return ONLY a JSON object, no markdown fence, no preamble:
{"streams":[{"title":"...","summary":"...","kind":"user|internal","prs":[123,456]}]}

PRs:
P

echo "{" > "$TMP/summary.json"
FIRST=1

for D in $WINDOWS; do
  SINCE="$(days_ago "$D")"

  jq -r --arg since "$SINCE" '
    [.prs[]
     | select(.mergedAt[0:10] >= $since)
     | select(.baseRefName == "next" or (.baseRefName | startswith("release/")))]
    | sort_by(.mergedAt)
    | .[] | "#\(.number)\t\(.baseRefName)\t\(.mergedAt[0:10])\t\(.title)"
  ' "$TMP/data.json" > "$TMP/prs.txt"

  N=$(wc -l < "$TMP/prs.txt" | tr -d ' ')
  if [ "$N" -eq 0 ]; then continue; fi
  echo "Summarizing $N PRs from the last $D days ..." >&2

  OK=0
  for ATTEMPT in 1 2; do
    { printf '%s\n' "$BRIEF"; cat "$TMP/prs.txt"; } \
      | claude -p --model "$MODEL" > "$TMP/resp.txt" || true

    # The model is asked for bare JSON but sometimes wraps or prefaces it.
    python3 -c 'import sys; t=sys.stdin.read(); i=t.find("{"); j=t.rfind("}"); sys.stdout.write(t[i:j+1] if i>=0 and j>i else "")' \
      < "$TMP/resp.txt" > "$TMP/raw.json"

    if jq -e '.streams | type == "array"' "$TMP/raw.json" >/dev/null 2>&1; then OK=1; break; fi
    echo "  attempt $ATTEMPT returned no usable JSON, retrying ..." >&2
  done

  if [ "$OK" -eq 0 ]; then
    cp "$TMP/resp.txt" "$DIR/summarize-failed-${D}d.txt"
    echo "  giving up on the $D day window; raw response saved to summarize-failed-${D}d.txt" >&2
    continue
  fi

  ALL=$(jq -c '[.[]]' <<< "[$(sed 's/^#\([0-9]*\).*/\1,/' "$TMP/prs.txt" | tr -d '\n' | sed 's/,$//')]")

  # Drop numbers the model invented, and sweep any it dropped into "Everything else".
  jq -c --argjson all "$ALL" '
    .streams |= map(.prs |= (map(select(. as $n | $all | index($n))) | unique))
    | ([.streams[].prs[]] | unique) as $covered
    | ($all - $covered) as $missing
    | if ($missing | length) > 0 then
        if ([.streams[].title] | index("Everything else")) then
          .streams |= map(if .title == "Everything else"
                          then .prs = ((.prs + $missing) | unique) else . end)
        else
          .streams += [{title: "Everything else",
                        summary: "Unrelated one-off changes.",
                        kind: "internal", prs: $missing}]
        end
      else . end
  ' "$TMP/raw.json" > "$TMP/clean.json"

  [ $FIRST -eq 1 ] || echo "," >> "$TMP/summary.json"
  FIRST=0
  printf '"%s": %s' "$D" "$(cat "$TMP/clean.json")" >> "$TMP/summary.json"
done

printf ',\n"generatedAt": "%s",\n"model": "%s"\n}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODEL" >> "$TMP/summary.json"

{ printf 'window.PR_SUMMARY = '; cat "$TMP/summary.json"; printf ';\n'; } > "$DIR/summary.js"
echo "Wrote $DIR/summary.js" >&2
