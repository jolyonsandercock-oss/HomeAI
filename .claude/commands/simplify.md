---
name: simplify
description: Strip over-engineering from recently written code before human review
---
Review the files written in the last step. Remove: unnecessary abstractions,
speculative error handling for problems that don't exist, defensive code beyond
what the spec requires, commented-out alternatives. Keep it simple and direct.
Report what was removed and why.
