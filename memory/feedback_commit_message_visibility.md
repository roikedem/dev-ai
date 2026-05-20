---
name: commit-message-visibility
description: Always show full commit message as text before making the git commit tool call — user can only see first 2 lines when they reject a tool use
metadata:
  type: feedback
---

Always print the full commit message as plain text output **before** issuing the `git commit` tool call, so the user can review the complete message and decide whether to approve the tool use.

**Why:** When the user rejects a tool call, most of the message content is hidden — only the first ~2 lines remain visible. Without seeing the full message upfront, the user has no way to review what they're approving.

**How to apply:** Every time you're about to commit, write the commit message as text in your response first, then make the tool call.
