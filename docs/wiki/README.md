# Home AI Wiki — shared mental models

Canonical knowledge base for EVERY agent on this box (Claude Code, Hermes,
future workers) and for humans. One source of truth — agents READ this rather
than maintaining parallel copies in their private memories.

Rules:
- Pages explain the TERRAIN (how a subsystem works + why it's shaped that way),
  not changelogs. Traps/rules live in each agent's own memory and link here.
- 200-400 words per page. Reasoning attached. Update the page when the
  architecture changes — stale wiki is worse than no wiki.
- Private agent memories (Claude auto-memory, Hermes Mnemosyne) must NOT
  duplicate page content — link to it.

Index:
- [realm-entity-isolation.md](realm-entity-isolation.md) — entity vs realm, RLS GUCs, PERMISSIVE/RESTRICTIVE, override pattern
- [invoice-pipeline.md](invoice-pipeline.md) — email → extraction ladder → vision-OCR → counterparty attribution
- [vault-role.md](vault-role.md) — secret access patterns, seal blast radius, circular-dep mitigations
- [n8n-topology.md](n8n-topology.md) — events table, master router, dead letters, runtime-edit traps
- [touchoffice-revenue-model.md](touchoffice-revenue-model.md) — why head_office is the only revenue truth
