#!/usr/bin/env bash
# Reading tracker CLI helper
# Usage:
#   ./update.sh add "Article Title" "https://url" "tag1,tag2" 20
#   ./update.sh done 3
#   ./update.sh reading 3
#   ./update.sh list
#   ./update.sh scan          # rebuild manifest.json from *.html files in this folder
#   ./update.sh push "optional commit message"

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JSON="$SCRIPT_DIR/readings.json"

cmd="${1:-list}"

require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: brew install jq"
    exit 1
  fi
}

case "$cmd" in

  list)
    require_jq
    echo ""
    WEEK=$(jq -r '.weeks[-1].label' "$JSON")
    echo "  📖  $WEEK"
    echo ""
    jq -r '.weeks[-1].articles[] | "  [\(.id)] \(.status | ascii_upcase | .[0:1]) \(.title) (\(.estimatedMinutes)m)"' "$JSON"
    echo ""
    DONE=$(jq '[.weeks[-1].articles[] | select(.status=="done")] | length' "$JSON")
    TOTAL=$(jq '.weeks[-1].articles | length' "$JSON")
    echo "  $DONE / $TOTAL done"
    echo ""
    ;;

  done|reading|todo)
    require_jq
    ID="${2:?Usage: ./update.sh $cmd <article_id>}"
    WEEK_IDX=$(jq '.weeks | length - 1' "$JSON")
    UPDATED=$(jq --argjson idx "$WEEK_IDX" --argjson id "$ID" --arg status "$cmd" \
      '.weeks[$idx].articles = [.weeks[$idx].articles[] | if .id == $id then .status = $status | if $status == "done" then .completedAt = (now | todate) else .completedAt = null end else . end]' \
      "$JSON")
    echo "$UPDATED" > "$JSON"
    TITLE=$(jq -r --argjson idx "$WEEK_IDX" --argjson id "$ID" '.weeks[$idx].articles[] | select(.id==$id) | .title' "$JSON")
    echo "  ✓  [$cmd] $TITLE"
    ;;

  add)
    require_jq
    TITLE="${2:?Usage: ./update.sh add <title> <url> <tags> <minutes>}"
    URL="${3:-#}"
    TAGS_RAW="${4:-}"
    MINS="${5:-15}"
    WEEK_IDX=$(jq '.weeks | length - 1' "$JSON")
    MAX_ID=$(jq '[.weeks[].articles[].id] | max // 0' "$JSON")
    NEW_ID=$((MAX_ID + 1))
    TAGS_JSON=$(echo "$TAGS_RAW" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)
    UPDATED=$(jq --argjson idx "$WEEK_IDX" \
      --argjson id "$NEW_ID" \
      --arg title "$TITLE" \
      --arg url "$URL" \
      --argjson tags "$TAGS_JSON" \
      --argjson mins "$MINS" \
      '.weeks[$idx].articles += [{ id: $id, title: $title, url: $url, tags: $tags, estimatedMinutes: $mins, status: "todo", notes: "", completedAt: null }]' \
      "$JSON")
    echo "$UPDATED" > "$JSON"
    echo "  ✓  Added: $TITLE"
    ;;

  scan)
    MANIFEST="$SCRIPT_DIR/manifest.json"
    EXCLUDE="reading-tracker.html index.html 6th_grade_math_worksheet.html"
    python3 - "$SCRIPT_DIR" "$MANIFEST" $EXCLUDE <<'PYEOF'
import sys, json, os, re

folder, out = sys.argv[1], sys.argv[2]
exclude = set(sys.argv[3:])

def title_from(f):
    name = re.sub(r'^\d{4}-\d{2}-\d{2}-', '', f).replace('.html','')
    words = name.replace('-', ' ').replace('_', ' ').split()
    keep_upper = {'vpc','aws','rest','api','jwt','tls','mtls','spiffe','spire','ebpf','sql','iam'}
    return ' '.join(w.upper() if w.lower() in keep_upper else w.capitalize() for w in words)

def tags_from(f):
    f = f.lower(); tags = []
    if any(k in f for k in ['iceberg','trino','delta','lakehouse','catalog','lake','parquet']): tags.append('data')
    if any(k in f for k in ['vpc','network','istio','ingress','egress','alb','nlb','link','endpoint']): tags.append('networking')
    if any(k in f for k in ['oauth','jwt','auth','iam','rbac','abac','identity','spiffe','tls','mtls']): tags.append('auth')
    if any(k in f for k in ['kubernetes','k8s','scheduler','ebpf','linux','container']): tags.append('systems')
    return tags if tags else ['data']

def date_from(f):
    m = re.match(r'^(\d{4}-\d{2}-\d{2})', f)
    return m.group(1) if m else None

files = sorted(f for f in os.listdir(folder) if f.endswith('.html') and f not in exclude)
existing = {}
try:
    with open(out) as fh:
        for a in json.load(fh).get('articles', []):
            existing[a['file']] = a
except: pass

articles = []
for f in files:
    if f in existing:
        articles.append(existing[f])
    else:
        articles.append({'file': f, 'title': title_from(f), 'tags': tags_from(f), 'date': date_from(f)})

with open(out, 'w') as fh:
    json.dump({'articles': articles}, fh, indent=2)

# Patch inline manifest block in reading-tracker.html
tracker = os.path.join(folder, 'reading-tracker.html')
inline_json = json.dumps({'articles': articles}, separators=(',', ':'))
# Build one-line-per-article pretty version for readability
lines = ['  "articles": [']
for i, a in enumerate(articles):
    comma = '' if i == len(articles)-1 else ','
    lines.append('    ' + json.dumps(a, separators=(', ', ': '))[:-1].replace('{"', '{"') + '}' + comma)
lines.append('  ]')
pretty = '{\n' + '\n'.join(lines) + '\n}'
try:
    with open(tracker) as fh: html = fh.read()
    import re as _re
    patched = _re.sub(
        r'<!-- MANIFEST-INLINE-START -->.*?<!-- MANIFEST-INLINE-END -->',
        f'<!-- MANIFEST-INLINE-START -->\n<script type="application/json" id="manifest-data">\n{pretty}\n</script>\n<!-- MANIFEST-INLINE-END -->',
        html, flags=_re.DOTALL)
    with open(tracker, 'w') as fh: fh.write(patched)
    print(f"  ✓  reading-tracker.html inline manifest updated")
except Exception as e:
    print(f"  !  Could not patch HTML: {e}")

print(f"  ✓  manifest.json updated ({len(articles)} articles)")
PYEOF
    ;;

  push)
    MSG="${2:-reading: update progress}"
    cd "$SCRIPT_DIR"
    git add readings.json manifest.json
    git commit -m "$MSG" 2>/dev/null || echo "  (nothing to commit)"
    git push
    echo "  ✓  Pushed"
    ;;

  *)
    echo "Usage: ./update.sh [list|done|reading|todo|add|push] ..."
    echo ""
    echo "  list                           Show current week"
    echo "  done <id>                      Mark article done"
    echo "  reading <id>                   Mark article in progress"
    echo "  todo <id>                      Reset to todo"
    echo "  add <title> <url> <tags> <min> Add new article"
    echo "  scan                           Rebuild manifest.json from *.html files"
    echo "  push [message]                 git add + commit + push"
    ;;
esac
