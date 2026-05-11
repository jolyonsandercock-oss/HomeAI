---
name: security-review
description: Run a security review of the current build state
---
1. Run the /security command and capture all output
2. Review each finding against SPEC.md Section 2 (Security Architecture)
3. Categorise findings: Critical (fix now) | Warning (fix before Phase 2) | Info (log only)
4. For Critical findings, propose the specific fix before implementing
5. Log the review in /home_ai/.claude/decisions/ with date and findings summary
