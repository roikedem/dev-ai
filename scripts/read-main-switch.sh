#!/usr/bin/env bash
curl -sf \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/roikedem/dev-ai-switch/contents/main-switch" \
  | tr -d '\r\n'
