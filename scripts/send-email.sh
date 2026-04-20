#!/usr/bin/env bash
# Usage: send-email.sh "to@example.com" "Subject" "path/to/body.html"
# Or pipe HTML: echo "<b>hi</b>" | send-email.sh "to@example.com" "Subject"

TO="${1:?Usage: send-email.sh <to> <subject> [html-file]}"
SUBJECT="${2:?missing subject}"
HTML_FILE="$3"

if [ -n "$HTML_FILE" ]; then
    BODY=$(cat "$HTML_FILE")
else
    BODY=$(cat)
fi

{
    echo "To: $TO"
    echo "Subject: $SUBJECT"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo ""
    echo "$BODY"
} | msmtp "$TO"
