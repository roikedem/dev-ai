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


name="רואי מהזרם"
from_email="roi@hazerem.com"
encoded=$(printf "%s" "$name" | base64)
header_from="=?UTF-8?B?${encoded}?= <$from_email>"

{
    echo "To: $TO"
    echo "From: $header_from"
    echo "Subject: $SUBJECT"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo ""
    echo "$BODY"
} | msmtp "$TO"
