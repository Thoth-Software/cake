# Cake Feature Roadmap: RAG Enhancements

A checklist of RAG capabilities for Cake, organised into eight capability areas plus cross-cutting design groundwork. Each area opens with a line of context and links to the relevant literature; the boxes are the roadmap.

**How to read this.** Checked items exist on `master`, verified against the commit history and current code as of 2026-08-13 (through #241); each cites its module and, where applicable, the PR that landed it. Unchecked items are not yet built. Items marked **(priority)** form the MVP threshold plus the immediate next steps; anything beyond them is explicitly backlog, not an implicit launch requirement. Ideas too open-ended to be checked off live in [Reach Goals](#reach-goals) at the end.

## Contents

- [1. Retrieval](#1-retrieval)
- [2. Chunking](#2-chunking)
- [3. Context Assembly](#3-context-assembly)
- [4. Augmented Generation](#4-augmented-generation)
- [5. Guardrails and Faithfulness](#5-guardrails-and-faithfulness)
- [6. Structured and Domain-Aware Retrieval](#6-structured-and-domain-aware-retrieval)
- [7. Conversational Memory](#7-conversational-memory)
- [8. Evaluation and Feedback Loops](#8-evaluation-and-feedback-loops)
- [Design Groundwork](#design-groundwork)
- [Reach Goals](#reach-goals)
- [Further Reading](#further-reading)

---

## 1. Retrieval

How candidate chunks are selected before the LLM sees anything; weak retrieval cannot be compensated for downstream. Cake treats retrieval as configurable, composable, observable pipeline stages.

References: [Wang et al. 2024](https://arxiv.org/abs/2407.01219) (best-practices study; hybrid + HyDE), [LevelRAG](https://arxiv.org/abs/2502.18139) (decomposition/planning), [AWS OpenSearch sparse+dense hybrid](https://aws.amazon.com/blogs/big-data/integrate-sparse-and-dense-vectors-to-enhance-knowledge-retrieval-in-rag-using-amazon-opensearch-service), [KG²RAG](https://arxiv.org/abs/2502.06864) (graph-guided re-ranking), [Verma et al. 2025](https://arxiv.org/abs/2507.05577) (re-ranker ensembles), [Pan et al. 2025](https://www.mdpi.com/2079-9292/14/9/1744) (Gaussian-kernel expansion), [Zhang et al. 2024](https://aclanthology.org/2024.findings-emnlp.103/) (query-expansion best practices).

- [x] Keyword, vector, and hybrid search modes, with hybrid as the default (`Cake.Search`; #31, #54)
- [x] Configurable hybrid weighting and per-field caret boosts (`Search.Query` `:boost`, `Cake.GDS.search_fields/0`)
- [x] Score normalisation and combination across retrieval signals (`Search.normalize_and_combine/1`, `score_results/2`)
- [x] Pluggable search-backend behaviour with OpenSearch implementation, Mox-substitutable (`Search.Backend`; #192)
- [x] LLM query decomposition into atomic sub-questions, as an opt-in collaborator (`Cake.Decomposition` behaviour + `.LLM` implementation; #235–#237)
- [x] Concurrent sub-question search fan-out with bounded concurrency and timeouts (#241)
- [ ] **(priority)** Cross-encoder re-ranking stage over a widened candidate pool (top-50/100 → top-k)
- [ ] **(priority)** HyDE-style query expansion (generate hypothetical answer → embed), optional per query, with a no-expansion A/B path
- [ ] Re-ranker score caching for repeated or canonical queries
- [ ] Adaptive candidate-pool sizing by query type (short vs. multi-hop)
- [ ] Retrieval configuration presets per corpus shape (documentation KB, code, FAQ-heavy)
- [ ] Evaluate OpenSearch neural sparse + dense against BM25 + dense on target corpora

## 2. Chunking

How raw documents are divided into embedding units; chunking strategy alone can move recall by five to ten points. Chunkers should be pluggable strategies with per-domain presets.

References: [Smith and Troynikov (Chroma) 2024](https://research.trychroma.com/evaluating-chunking) (chunking evaluation), [Merola and Singh 2025](https://arxiv.org/abs/2504.19754) (late chunking vs. contextual retrieval), [Tripathi et al. 2025](https://arxiv.org/abs/2506.16035) (vision-guided chunking for PDFs).

- [x] Chunk-level metadata: page number, section title, chunk index, word/char counts (`Cake.Books.Chunk` schema; #62)
- [x] Structure-derived retrieval units for documentation: one retrievable per documentation entry (`ParsedDocument`; #27)
- [ ] **(priority)** Semantic chunking for books using headings/paragraph/list cues — current PDF chunking is one chunk per page (`Cake.Books.Pdf.Pipeline`)
- [ ] **(priority)** Configurable overlapping windows per index
- [ ] Chunking profiles per document type (long-form policy vs. code/API docs)
- [ ] LLM-fallback chunker for unstructured documents, with aggressive caching
- [ ] Multi-representation chunks: multiple embeddings per chunk (raw text + summary/entities) with query-time weighting

## 3. Context Assembly

Deciding what reaches the LLM and in what form: deduplication, grouping, and labelling of retrieved chunks. Most frameworks treat this as an afterthought; Cake makes it a pipeline stage.

- [x] Relevance-floor and chunk-ceiling filtering with dense 1..N prompt indices (`Prompt.prepare_context/2`)
- [x] Neighbor expansion around direct hits, with merged ranges and per-book deduplication (`Books.Retrieval`, `Cake.GDS.expand_with_neighbors/2`)
- [x] Cross-sub-question result deduplication when merging decomposed searches into one context (#239)
- [x] Struct-rendered prompt context via protocol, per retrievable type (`Cake.Promptable`)
- [ ] **(priority)** Formal `ContextBuilder` stage: near-duplicate removal by similarity, grouping by document, metadata/role attachment
- [ ] Per-document consolidation via extractive summarisation, with citation back-links to source chunks, plus a strict mode (exact chunks only) for high-risk queries
- [ ] Section-aware assembly: labelled buckets (definitions/procedures/examples) in the prompt scaffold
- [ ] Role annotation of chunks (facts, constraints, examples, history) with conflict-priority instructions

## 4. Augmented Generation

Structuring the reasoning process — retrieve, reason over evidence, then answer — rather than raw prompt-and-pray. Generation pipeline templates are procedural, not just prompts.

References: [Plan\*RAG](https://arxiv.org/abs/2410.20753) (plan-then-retrieve), [LevelRAG](https://arxiv.org/abs/2502.18139).

- [x] The per-turn flow is an explicit staged pipeline: decompose → search → select → prompt → generate → cite (`Conversation.run_turn/2`; #140, #141)
- [x] Structured JSON completion callback for machine-readable LLM outputs (`Generation.complete_json/3`; #234)
- [ ] Stock reasoning templates (evidence extraction, compare-and-contrast) with intermediate steps logged for analysis, hidden from end users
- [ ] Multi-stage retrieval planning with the plan as an explicit data structure and iterative retrieval — decomposition today is single-shot, one fan-out per turn

## 5. Guardrails and Faithfulness

Preventing and detecting unfaithful answers; enterprise adoption requires a trust story of faithfulness checks, citation quality, and monitored hallucination rates.

References: [Tamber et al. 2025](https://arxiv.org/abs/2505.04847) (FaithJudge), [Wallat et al. 2024](https://arxiv.org/abs/2412.18004) (correctness ≠ faithfulness), [Sok et al. 2025](https://arxiv.org/abs/2509.09360) (MetaRAG metamorphic testing), [CiteFix](https://arxiv.org/abs/2504.15629), [RAGE toolkit](https://aclanthology.org/2024.konvens-main.6/) (citation metrics).

- [x] Inline `[N]` citations parsed from responses, resolved against the chunk map, deduplicated, ordered (`Cake.Citations`, `Cake.Responses`; #67)
- [x] Hallucinated citation markers (indices with no backing chunk) filtered out in post-processing (`Cake.Citations`)
- [x] Generic citation data model — exactly `id`, `label`, `source_ref`, `preview`, `extras` — per retrievable type (`Cake.Citable` protocol)
- [ ] **(priority)** Basic answer/citation logging for offline inspection: which chunks retrieved, which cited, per turn
- [ ] LLM-as-judge faithfulness scorer over answer + retrieved context, binary safe/unsafe thresholds
- [ ] Citation-correctness evaluation and repair (CiteFix-style post-processing)
- [ ] Metamorphic tests in the evaluation suite

## 6. Structured and Domain-Aware Retrieval

Beyond documents-as-bags-of-words: schemas, graphs, and domain structure as retrieval sources.

References: [Cheerla 2025](https://arxiv.org/abs/2507.12425) (structured-data RAG), [KG²RAG](https://arxiv.org/abs/2502.06864), [GGR](https://openreview.net/forum?id=R1NWMExESj) (GNN-guided prompting), [Microsoft GraphRAG](https://arxiv.org/abs/2404.16130).

- [ ] Schema ingestion interface: metadata-aware filters from a table/API definition, joining structured results with text context
- [ ] Graph hooks for tenants with existing knowledge graphs
- [ ] Basic document-derived entity graph (entities + document IDs + links)
- [ ] Preferred-vocabulary configuration (logit bias over a small curated term list)

## 7. Conversational Memory

Multi-turn RAG: tracking what has been said, retrieved, and decided. A conversation is a stateful process — a natural fit for Elixir/OTP.

References: [MTRAG](https://arxiv.org/abs/2501.03468) (multi-turn benchmark), [Wu et al. 2025](https://arxiv.org/abs/2504.15965) (memory-mechanisms survey).

- [x] Conversation as a stateful process: GenServer with a turn state machine, message history, accumulated citations and errors (`Cake.Conversation` + `Conversation.State`; #138–#141)
- [x] Follow-up turns reuse cached retrieval results instead of re-searching (`Cake.Conversation`)
- [x] Manual-selection mode: retrieve candidates, let the user choose documents, then generate (`manualask/2` + `select_docs/2`; #143)
- [ ] Conversation memory store and retrieval hook separate from the main KB, bounded (last N turns + summary)
- [ ] Long-term memory interface: timestamped, confidence-scored facts with cautious LLM-mediated updates
- [ ] Reference-resolution pipeline step: rewrite the raw query into a de-referenced query before retrieval

## 8. Evaluation and Feedback Loops

Constant measurement of retrieval quality, generation faithfulness, and drift. First-class evaluation tooling is a differentiator.

References: [ARES](https://aclanthology.org/2024.naacl-long.20/) (synthetic queries + LLM judges), [FRAMES](https://arxiv.org/abs/2409.12941) (factuality/retrieval/reasoning benchmark), [Rahmani et al. 2024](https://arxiv.org/abs/2405.07767) (synthetic test collections).

- [x] Item-level ingestion failures persisted with pipeline provenance and retried via sweep (`FailedIngest`, `Pipelines.detuple_with_logging/3`, `sweep/5`; #72, #76, #77)
- [x] Per-result retrieval provenance: search conditions, backend and CAKE scores, decomposition traceability (`Search.Result`, `Search.Provenance`; #154, #238)
- [ ] **(priority)** Synthetic evaluation kit: generate queries + answers from a corpus, run them through pipelines, report recall/precision/faithfulness
- [ ] Human-validated subset mixed into synthetic eval sets
- [ ] Drift KPIs with alerting on deltas: context recall, answer faithfulness, user feedback rates
- [ ] Multi-turn evaluation (MTRAG-style) over conversation flows

## Design Groundwork

Structural decisions that keep the above buildable without rework.

- [x] Pipelines are first-class: behaviour contracts per GDS, result tuples at every step, shared error-handling infrastructure (`Cake.Pipelines`, `Books.Pipeline`, `Documents.Pipeline`)
- [x] Search layer decoupled from ingestion contexts via `:search_collections` config; boundaries compiler-enforced (#192, #214)
- [x] Collaborator modules injected as opts/config for Mox substitution throughout (embeddings, generation, responses, decomposition, backend)
- [ ] Declarative pipeline configuration (YAML/JSON) so retrieval recipes are config, not code
- [ ] OpenSearch document schema extended for multiple vector fields per chunk (raw, summary, entities)
- [ ] Conversation memory split into its own index/store with a clean API boundary to corpus retrieval
- [ ] Tenant concept: per-tenant indices, retrieval recipes, and configuration — today the app is single-endpoint with fixed collection names

## Reach Goals

Directions too open-ended to be checklist items yet — candidates for promotion once scoped.

- Learn per-tenant hybrid fusion weights from minimal user feedback (clicks, ratings)
- Re-rank chunk groups (whole documents/sections) rather than individual chunks; multi-objective re-ranking (relevance + recency + access control)
- Graph-aware re-rankers that treat a document and its graph neighbours as one unit
- Multi-embedding query expansion in a learned semantic space ([Pan et al. 2025](https://www.mdpi.com/2079-9292/14/9/1744)-style), or retrieval-grounded expansion re-scoring ([RFG](https://www.scitepress.org/Link.aspx?doi=10.5220/0013836900004000)-style)
- A customer-facing chunking evaluation lab: upload a corpus, compare chunking configurations side by side with metrics
- Published research artifacts: a "Cake Retrieval Study" (neural sparse vs. BM25 hybrids on enterprise corpora) and "Multi-Representation Chunking for Enterprise RAG with OpenSearch"
- Evolve from RAG framework toward a RAG substrate for enterprise systems, plugging into existing schemas and graphs
- Position conversation-aware RAG and built-in evaluation as the core product story ("we measure and monitor, not just build")
- Auto-suggest preferred-vocabulary lists from a tenant's corpus
- Framework-level drift dashboards per corpus, tenant, and model version

## Further Reading

A curated shelf of current work worth tracking, grouped by what it means for Cake. These are not roadmap commitments — they are the frontier the roadmap should be steered against. Links verified as of 2026-08.

### Agentic retrieval and learned planning

Where the decompose → retrieve → answer loop is heading: models trained to decide when and what to retrieve, rather than pipelines that hard-code it.

- [**Search-R1: Training LLMs to Reason and Leverage Search Engines with Reinforcement Learning**](https://arxiv.org/abs/2503.09516) (Jin et al., 2025) — RL-trains an LLM to interleave multi-turn search calls inside its reasoning chain, beating standard RAG baselines by 20–41%. The founding paper of the agentic-search-RL line, and the template for what could eventually replace a hand-written decomposition loop like `Cake.Decomposition`.
- [**Chain-of-Retrieval Augmented Generation (CoRAG)**](https://arxiv.org/abs/2501.14342) (Wang et al., Microsoft Research, 2025; NeurIPS 2025) — trains models to plan chains of retrievals, reformulating the query as evidence accumulates, and studies test-time scaling of retrieval steps. The natural successor to single-shot decomposition.
- [**Tongyi DeepResearch Technical Report**](https://arxiv.org/abs/2510.24701) (Tongyi Lab, 2025) — the strongest fully open deep-research agent (30.5B MoE), trained end-to-end on synthetic agentic data. The best public blueprint of a production-grade iterative-retrieval stack.
- [**Recursive Language Models**](https://arxiv.org/abs/2512.24601) (Zhang et al., MIT CSAIL, 2025) — treats a long prompt as an environment the model programmatically inspects, chunks, and recursively calls itself over, handling inputs roughly 100× the context window. Reframes the long-context-vs-RAG debate as "retrieval is recursive inference-time decomposition".

### Retrievers, rankers, and representations

- [**ReasonIR: Training Retrievers for Reasoning Tasks**](https://arxiv.org/abs/2504.20595) (Shao et al., Meta FAIR/UW, 2025) — the first retriever trained specifically for reasoning-intensive queries, via synthetic hard queries and plausible-but-unhelpful hard negatives. Evidence that similarity-trained embedders underperform once queries require inference — relevant to any embedding-model choice.
- [**Qwen3 Embedding**](https://arxiv.org/abs/2506.05176) (Qwen team, 2025) — the current default open embedding + reranker family (Apache-2.0, instruction-tunable, Matryoshka dimensions); a practical answer to which open models to plug into the dense and re-ranking stages. The follow-up [Qwen3-VL-Embedding and Reranker](https://arxiv.org/abs/2601.04720) (2026) extends the same stack to images, document screenshots, and video in one vector space.
- [**ColPali: Efficient Document Retrieval with Vision Language Models**](https://arxiv.org/abs/2407.01449) (Faysse et al., ICLR 2025) — OCR-free visual document retrieval: ColBERT-style late interaction over patch embeddings of page images. Directly relevant to PDF-heavy ingestion — retrieval over page images instead of lossy parsed text.
- [**MUVERA: Multi-Vector Retrieval via Fixed Dimensional Encodings**](https://arxiv.org/abs/2405.19504) (Dhulipala, Jayaram et al., Google Research) — compresses ColBERT/ColPali-style multi-vector sets into single fixed-dimension vectors whose inner product provably approximates MaxSim, making late-interaction retrieval servable on ordinary ANN infrastructure. What makes the ColPali lineage production-feasible.
- [**Towards Competitive Search Relevance for Inference-Free Learned Sparse Retrievers**](https://arxiv.org/abs/2411.04403) (Geng et al., Amazon OpenSearch neural-sparse team, 2024–25) — document-side-only learned sparse retrieval approaching SPLADE relevance on a plain Lucene inverted index, with zero query-time inference cost. Maximally relevant to Cake's stack: a third hybrid signal that is nearly free at query time.
- [**Late Chunking: Contextual Chunk Embeddings Using Long-Context Embedding Models**](https://arxiv.org/abs/2409.04701) (Günther et al., Jina AI) — embed the whole document through a long-context encoder first and chunk the token embeddings afterward, so every chunk vector carries document-wide context. The cheapest known fix for the context-stripping problem that page-per-chunk pipelines share.

### Context engineering and long context

- [**Context Rot: How Increasing Input Tokens Impacts LLM Performance**](https://research.trychroma.com/context-rot) (Hong, Troynikov, Huber — Chroma, 2025) — eighteen frontier models degrade non-uniformly with input length, even on trivial tasks, and distractors make it worse. The empirical backbone of "retrieve tightly, don't stuff the window".
- [**NoLiMa: Long-Context Evaluation Beyond Literal Matching**](https://arxiv.org/abs/2502.05167) (Modarressi et al., ICML 2025) — needle-in-a-haystack with no lexical overlap between needle and question: most models collapse below 50% of their short-context baseline by 32K tokens. Data against the "just use long context instead of retrieval" argument.
- [**Effective Context Engineering for AI Agents**](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (Anthropic, 2025) — the post that codified context engineering as a discipline: context as a finite resource, compaction, structured note-taking, just-in-time retrieval, sub-agent architectures. Reframes what a RAG framework's job is once its consumer is an agent rather than a single prompt.
- [**REFRAG: Rethinking RAG based Decoding**](https://arxiv.org/abs/2509.01092) (Lin et al., Meta, 2025) — feeds precomputed compressed chunk embeddings directly to the decoder, expanding only the chunks an RL policy deems worth full tokens: up to ~30× faster time-to-first-token at matched accuracy. The most credible context-compression result for high-throughput serving.
- [**DeepSeek-OCR: Contexts Optical Compression**](https://arxiv.org/abs/2510.18234) (DeepSeek-AI, 2025) — a 3B VLM that decodes document pages from ~100 vision tokens at ~97% precision (about 10× compression versus text tokens). State-of-the-art ingestion parsing, and a provocation about whether "chunk as text" is the right substrate at all.

### Evaluation, citations, and memory

- [**Reliability without Validity**](https://arxiv.org/abs/2606.19544) (Norman, 2026) — a systematic evaluation of 21 LLM-as-judge models: agreement metrics overstate discriminative ability, and judge rankings are unstable across datasets. Required reading before wiring an LLM judge into CI as a quality gate (see §8).
- [**Generation-Time vs. Post-hoc Citation: A Holistic Evaluation of LLM Attribution**](https://arxiv.org/abs/2509.21557) (Saxena et al., 2025) — cite-while-generating versus attribute-after-drafting is a coverage/correctness trade-off, with retrieval quality the dominant driver of attribution quality. Load-bearing for where the citation step sits in Cake's turn pipeline.
- [**Cited but Not Verified: Parsing and Evaluating Source Attribution in LLM Deep Research Agents**](https://arxiv.org/abs/2605.06635) (Onweller, 2026) — audits deployed research agents and finds 11–57% citation hallucination rates, proposing a three-axis check: link resolves, content relevant, fact supported. A ready-made rubric for end-to-end evaluation of `Citable` output.
- [**Memory OS of AI Agent**](https://arxiv.org/abs/2506.06326) (Kang et al., 2025) — an OS-inspired three-tier memory manager (short/mid/long-term) with dynamic promotion and eviction; the most-cited post-MemGPT memory design, and a plausible growth path for a long-lived `Conversation` process. Pair with [MemoryAgentBench](https://arxiv.org/abs/2507.05257) (Hu et al., 2025–26), which finds no current memory system masters accurate retrieval, test-time learning, long-range understanding, and selective forgetting at once.
- [**OP-Bench: Benchmarking Over-Personalization**](https://arxiv.org/abs/2601.13722) (Hu, 2026) — memory-augmented personalization backfires in three measurable patterns: irrelevance, repetition, sycophancy. The failure-mode catalogue to consult before building any per-user memory feature.

### Security and structured data

- [**PoisonedRAG: Knowledge Corruption Attacks to Retrieval-Augmented Generation**](https://arxiv.org/abs/2402.07867) (Zou et al., USENIX Security 2025) — roughly five injected documents in a 2.6M-text corpus steer answers to attacker-chosen outputs with ~97% success. The paper that made "who can write to the index?" a security question every enterprise RAG deployment must answer.
- [**Architecture Matters: Comparing RAG Systems under Knowledge Base Poisoning**](https://arxiv.org/abs/2605.05632) (Korn, 2026) — poisoning success varies from 81.9% for naive retrieve-and-stuff down to 24.4% for more mediated designs: pipeline architecture is itself a poisoning defense.
- [**Spider 2.0: Evaluating Language Models on Real-World Enterprise Text-to-SQL Workflows**](https://arxiv.org/abs/2411.07763) (Lei et al., ICLR 2025) — 632 real enterprise workflow problems over 1,000+-column schemas; the best reasoning models solve about a fifth of them. Defines the actual difficulty behind §6's schema-aware retrieval.
- [**LinearRAG: Linear Graph Retrieval Augmented Generation on Large-scale Corpora**](https://arxiv.org/abs/2510.10114) (Zhuang et al., 2025) — graph RAG without LLM relation extraction: lightweight entity extraction plus semantic linking, with construction cost linear in corpus size. The pragmatic on-ramp for §6's document-derived entity graph.
