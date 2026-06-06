## ArcRift Analysis — Open Question for Claude Code

Read AGENTS.md, then the relevant section of SPEC.md (Part 4 — System Architecture / Pipelines, and the Qdrant/RAG sections). Don't implement anything yet. I want your analysis.

### Background

ArcRift (github.com/Eshaan-Nair/ArcRift, MIT, v1.6.3) is a local-first RAG/memory layer for AI coding tools. It captures browser AI chats (Claude, ChatGPT, DeepSeek etc.), builds a searchable knowledge graph with a Chrome extension + MCP server, and injects context into new prompts. Runs on SQLite + sqlite-vec + Ollama (nomic-embed-text). No Docker.

### What it does that we might want

1. **HyDE Retrieval (Hypothetical Document Embeddings)**
   Before searching Qdrant, a cheap LLM generates a synthetic answer to the query, then you embed THAT answer instead of the raw query. Proven to improve recall on rephrased/vague queries — ArcRift benchmarks 90% recall with 95% noise compression using this.

2. **Async embedding queue with retry + dead letter queue**
   Saves are instant. Embeddings happen in background. Failed jobs retry 5 times then land in a visible dead letter queue. Our current AI enrichment pipeline has no equivalent — if Ollama chokes mid-embedding (which happens when the 3060 is under gaming load), the event just fails.

3. **Browser extension for AI chat capture**
   Silently intercepts prompts from 7 web-based AI platforms and saves them locally. We already capture Claude Code sessions via Hermes, but NOT web-based chats (Claude web UI, ChatGPT, DeepSeek web). Every architectural decision about Home AI that happens in a browser chat is currently lost to the event system.

### What we already have that overlaps

- Qdrant v1.17.1 (Docker) for vector search — nomic-embed-text via Ollama
- PostgreSQL tsvector FTS on email_chunks and research_corpus
- Hermes session_search() + memory() for cross-session context
- PostgreSQL RLS with entity isolation (SET LOCAL app.current_entity)
- body_text_safe sanitised pipeline for PII
- Full relational schema with entity relationships (our "knowledge graph" is the DB itself)

### Questions to answer (Plan Mode — don't implement)

1. **HyDE**: Worth adding as an n8n node before Qdrant queries? It's maybe 20 lines — generate answer via qwen2.5:7b, embed that, search Qdrant with it. Cost: one extra local LLM call per query. Benefit: 90% recall on vague queries. Worth it for our use case (business data queries, not codebase search)?

2. **Async embedding queue**: Do we actually have a problem here? Check whether any enrichment pipeline steps fail silently when Ollama is unavailable. If yes, what does a dead-letter-queue pattern look like in n8n? Is this a real gap or a theoretical one?

3. **Browser chat capture**: Do I do enough AI work in web UIs (vs Claude Code in terminal) for this to matter? Be honest. If the answer is "Jo uses Claude Code 90% of the time and the web UI 10%," then Hermes already captures the important stuff and this isn't worth building.

4. **Overall verdict**: Is ArcRift solving the same problem as Home AI, or a different one? If it's different, are there genuinely transferable patterns, or are we just chasing shiny things?

### Output I want

A markdown analysis in /home_ai/.hermes/arcrift-analysis-response.md with:
- Answers to all four questions above
- A clear recommendation: adopt HyDE? build async queue? bother with browser capture?
- If YES on anything: which Phase/Step it belongs in, and rough effort estimate
- If NO on everything: a clean kill decision with reasoning so I don't revisit this

Don't implement anything. This is an analysis, not a build step.
