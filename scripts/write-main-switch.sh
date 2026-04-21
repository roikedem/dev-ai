#!/usr/bin/env bash
gh api \
  --method PATCH \
  repos/roikedem/dev-ai/actions/variables/MAIN_SWITCH \
  -f name=MAIN_SWITCH \
  -f value="${1}"
