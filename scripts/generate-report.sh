#!/usr/bin/env bash
# Called by Claude to generate an HTML issue report with embedded screenshots.
# Usage: generate-report.sh <project-dir> <output.html>
# Reads issue data from stdin as JSON array:
# [{"key":"PAN-195","type":"Task","summary":"...","resolved":"2026-04-19","description":"..."},...]

PROJECT_DIR="${1:?Usage: generate-report.sh <project-dir> <output.html>}"
OUTPUT="${2:-/tmp/pandit-report.html}"
SCREENSHOTS_DIR="$PROJECT_DIR/docs/screenshots"
TODAY=$(date '+%B %-d, %Y')

# Read issue JSON from stdin
ISSUES_JSON=$(cat)

embed_image() {
    local file="$1"
    local label="$2"
    if [ -f "$file" ]; then
        local b64
        b64=$(base64 -w 0 "$file")
        local ext="${file##*.}"
        echo "<div><div style='font-size:11px;color:#888;margin-bottom:4px;'>$label</div><img src='data:image/$ext;base64,$b64' style='max-width:100%;border:1px solid #ddd;border-radius:4px;'></div>"
    fi
}

cat > "$OUTPUT" <<HEAD
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
  body { font-family: Arial, sans-serif; color: #333; max-width: 700px; margin: 40px auto; padding: 0 20px; }
  h1 { color: #1a1a2e; border-bottom: 2px solid #4a90d9; padding-bottom: 10px; }
  h2 { color: #4a90d9; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; margin-top: 30px; }
  .issue { background: #f9f9f9; border-left: 4px solid #4a90d9; padding: 14px 18px; margin: 12px 0; border-radius: 0 4px 4px 0; }
  .issue-key { font-weight: bold; color: #4a90d9; font-size: 13px; }
  .issue-title { font-size: 16px; font-weight: bold; margin: 4px 0 6px; }
  .issue-meta { font-size: 12px; color: #888; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: bold; margin-left: 8px; }
  .badge-done { background: #e6f4ea; color: #2e7d32; }
  .badge-bug { background: #fdecea; color: #c62828; }
  .badge-task { background: #e8f0fe; color: #1a56db; }
  .screenshots { display: flex; gap: 16px; margin-top: 12px; flex-wrap: wrap; }
  .screenshots > div { flex: 1; min-width: 200px; }
  .footer { margin-top: 40px; font-size: 12px; color: #aaa; border-top: 1px solid #eee; padding-top: 14px; }
</style>
</head>
<body>
<h1>Pandit Project — Development Report</h1>
<p style="color:#666; font-size:14px;">Issues resolved as of $TODAY</p>
<h2>Completed Issues</h2>
HEAD

echo "$ISSUES_JSON" | jq -c '.[]' | while IFS= read -r issue; do
    KEY=$(echo "$issue" | jq -r '.key')
    SUMMARY=$(echo "$issue" | jq -r '.summary')
    TYPE=$(echo "$issue" | jq -r '.type')
    RESOLVED=$(echo "$issue" | jq -r '.resolved')
    DESCRIPTION=$(echo "$issue" | jq -r '.description')
    TYPE_CLASS=$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')

    BEFORE_HTML=$(embed_image "$SCREENSHOTS_DIR/$KEY/before.png" "Before")
    AFTER_HTML=$(embed_image "$SCREENSHOTS_DIR/$KEY/after.png" "After")
    SCREENSHOTS_HTML=""
    if [ -n "$BEFORE_HTML" ] || [ -n "$AFTER_HTML" ]; then
        SCREENSHOTS_HTML="<div class='screenshots'>$BEFORE_HTML$AFTER_HTML</div>"
    fi

    cat >> "$OUTPUT" <<ISSUE
<div class="issue">
  <div class="issue-key">$KEY <span class="badge badge-done">Done</span> <span class="badge badge-$TYPE_CLASS">$TYPE</span></div>
  <div class="issue-title">$SUMMARY</div>
  <div class="issue-meta">Resolved: $RESOLVED</div>
  <p style="margin-top:8px;font-size:14px;">$DESCRIPTION</p>
  $SCREENSHOTS_HTML
</div>
ISSUE
done

cat >> "$OUTPUT" <<FOOT
<div class="footer">
  Pandit Project &nbsp;·&nbsp; panditproject.org &nbsp;·&nbsp; Generated $TODAY
</div>
</body>
</html>
FOOT

echo "Report written to $OUTPUT"
