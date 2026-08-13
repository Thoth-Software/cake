# Cake Feature Roadmap: RAG Enhancements

This document surveys the RAG techniques most relevant to Cake's evolution, organised into eight capability areas. Each subsection describes the technique, its trade-offs, mitigations for the main risks, relevant recent work, and the direction it suggests for Cake. The closing [Recommendations](#recommendations) section distils the survey into concrete priorities.

## Contents

- [1. Retrieval](#1-retrieval)
  - [1.1 Hybrid Search](#11-hybrid-search)
  - [1.2 Re-ranking Pipelines](#12-re-ranking-pipelines)
  - [1.3 Query Expansion](#13-query-expansion)
- [2. Chunking](#2-chunking)
  - [2.1 Semantic Chunking](#21-semantic-chunking)
  - [2.2 Overlapping Windows](#22-overlapping-windows)
  - [2.3 Multi-Representation Chunks](#23-multi-representation-chunks)
- [3. Context Assembly](#3-context-assembly)
  - [3.1 Deduplication and Consolidation](#31-deduplication-and-consolidation)
  - [3.2 Section-Aware Assembly](#32-section-aware-assembly)
  - [3.3 Role-Annotated Context](#33-role-annotated-context)
- [4. Augmented Generation](#4-augmented-generation)
  - [4.1 Contextual Reasoning Chains](#41-contextual-reasoning-chains)
  - [4.2 Retrieval-Augmented Planning](#42-retrieval-augmented-planning)
- [5. Guardrails and Faithfulness](#5-guardrails-and-faithfulness)
  - [5.1 Faithfulness Checks](#51-faithfulness-checks)
  - [5.2 Citation Mode](#52-citation-mode)
- [6. Structured and Domain-Aware Retrieval](#6-structured-and-domain-aware-retrieval)
  - [6.1 Schema-Aware Retrieval](#61-schema-aware-retrieval)
  - [6.2 Graph-Augmented Retrieval](#62-graph-augmented-retrieval)
  - [6.3 Vocabulary Steering](#63-vocabulary-steering)
- [7. Conversational Memory](#7-conversational-memory)
  - [7.1 Conversation-Aware Retrieval](#71-conversation-aware-retrieval)
  - [7.2 Long-Term Memory](#72-long-term-memory)
  - [7.3 Multi-Turn Reference Disambiguation](#73-multi-turn-reference-disambiguation)
- [8. Evaluation and Feedback Loops](#8-evaluation-and-feedback-loops)
  - [8.1 Synthetic Query Evaluation](#81-synthetic-query-evaluation)
  - [8.2 Drift Detection](#82-drift-detection)
- [Recommendations](#recommendations)
  - [A. Immediate Priorities](#a-immediate-priorities)
  - [B. MVP Design Changes](#b-mvp-design-changes)
  - [C. Scaling Considerations](#c-scaling-considerations)
  - [D. Early Differentiators](#d-early-differentiators)
  - [Risks](#risks)

---

## 1. Retrieval

Retrieval determines which candidate chunks are selected from the corpus before the LLM sees anything. Weak retrieval cannot be compensated for downstream; in production RAG systems it typically accounts for the majority of answer quality. Hybrid search, re-ranking, and query expansion are three levers for improving recall and precision beyond cosine similarity on a single embedding.

**Relevance to Cake.** Cake is a framework, not a single application, so the retrieval layer must be:

- **Configurable** — per-tenant and per-domain retrieval recipes.
- **Composable** — query → retrieve → re-rank → post-filter.
- **Observable** — it should be possible to see why a given query failed.

Hybrid search, re-ranking, and query expansion should all be first-class pipeline stages that Cake exposes.

### 1.1 Hybrid Search

**What it is.** Combine sparse retrieval (BM25 or neural sparse) with dense (embedding-based) retrieval into one ranked list, either via score fusion (e.g. a weighted sum) or a multi-stage arrangement (BM25 followed by a dense filter, or vice versa). Hybrid retrieval is now widely regarded as the best default for RAG.

**Benefits**

- Substantially more robust across query types: sparse handles rare terms, identifiers, and codes; dense handles paraphrase and fuzzy language.
- Well suited to enterprise knowledge bases that mix jargon with natural language.
- Maps directly onto OpenSearch, which provides BM25, dense, and neural sparse retrieval out of the box.

**Trade-offs**

- Score fusion is sensitive to how sparse and dense scores are weighted.
- Multiple retrievers add latency and infrastructure complexity.
- Untuned BM25 can over-emphasise long documents or noisy fields.

**Mitigations**

- Learn fusion weights per index or per tenant (grid search or a small regression model suffices).
- Normalise scores per retriever (z-score or min–max).
- Use metadata filters and field-specific boosts (e.g. title over body) to keep BM25 well behaved.

**Relevant work**

- Wang et al., 2024, *Searching for Best Practices in Retrieval-Augmented Generation* — a broad empirical study of RAG configurations (retrievers, chunking, re-ranking) finding that hybrid search combined with HyDE-style query rewriting is often the best accuracy/latency trade-off. For Cake, their recommended "hybrid + HyDE" recipe is a strong candidate for the default retrieval preset.
- Zhang et al., 2025, *LevelRAG: Enhancing Retrieval-Augmented Generation with Multi-hop Logic Planning over Rewriting Augmented Searchers* — decomposes complex queries into atomic sub-queries routed across multiple retrievers, independent of retriever-specific optimisation. Aligns with a "structured retrieval" preset combining graph, dense, and re-ranking stages.
- AWS OpenSearch hybrid retrieval guidance (2024) — demonstrates neural sparse + dense hybrids on OpenSearch, directly applicable to Cake's stack. Suggests shipping a standard OpenSearch hybrid retriever module with tunable weights and field boosts, plus configuration templates for common corpus shapes (documentation, code, FAQ-heavy knowledge bases).
- Domain-specific hybrid QA studies (2024–2025) report that dense + BM25 hybrids significantly improve question answering in specialised domains.

**Open questions**

- Learn per-tenant fusion weights from minimal feedback signals (clicks, explicit ratings).
- Evaluate whether OpenSearch neural sparse + dense outperforms classic BM25 + dense for Cake's target enterprise domains, and publish the results as a retrieval study.

### 1.2 Re-ranking Pipelines

**What it is.** Two-stage retrieval: first gather a large candidate pool (top-50 to top-100 chunks), then score each candidate more precisely with a cross-encoder or an LLM acting as re-ranker, producing a much stronger top-5.

**Benefits**

- Large quality improvement, especially in noisy knowledge bases with duplicate documents and boilerplate.
- Keeps recall high while controlling the LLM context size.
- Valuable in high-stakes domains (compliance, finance, medical).

**Trade-offs**

- Added latency from scoring 50–100 candidates with a heavier model.
- Additional serving infrastructure (GPU/CPU capacity, batching, caching).
- Re-ranking cannot compensate for poor first-stage retrieval.

**Mitigations**

- Use efficient cross-encoders (e.g. MiniLM, MPNet) and batch requests across tenants.
- Cache re-ranker scores for repeated queries and canonical question templates.
- Adapt candidate pool size to the query (e.g. k=30 for short queries, k=100 for multi-hop).

**Relevant work**

- Zhu et al., 2025, *KG²RAG* — combines semantic retrieval with knowledge-graph-guided organisation and cross-encoder re-ranking. Points toward graph-aware re-rankers as an advanced option for tenants with graph data.
- *Beyond Retrieval: Ensembling Cross-Encoders and GPT* (2025) — ensembles cross-encoders with LLM re-rankers for biomedical QA. Motivates pluggable re-ranker backends in Cake ("lightweight cross-encoder", "LLM re-ranker", "ensemble"), configurable per tenant.
- Industry analyses (Pinecone, Databricks, and others) consistently identify re-ranking as one of the simplest high-impact additions to a RAG stack.

**Open questions**

- Re-rank chunk *groups* (all chunks from the same document or section) rather than individual chunks.
- Multi-objective re-ranking for enterprise use: relevance combined with recency and access control.

### 1.3 Query Expansion

**What it is.** Automatically expand or rewrite a user query into richer representations: paraphrases, related terms, or synthetic "ideal answers" that are then used for retrieval. Includes HyDE-style approaches (generate a hypothetical answer and embed it) and LLM-based expansion variants.

**Benefits**

- Compensates for short or vague queries ("VPN broken", "hr policy maternity").
- Bridges lexical gaps: synonyms, abbreviations, multilingual phrasing.
- Particularly effective in combination with hybrid retrieval.

**Trade-offs**

- Expansions can drift, introducing irrelevant concepts.
- Generating many expansions per query is computationally expensive.
- Can reduce precision by pulling in tangential documents.

**Mitigations**

- Limit expansion to two or three short variants.
- Use retrieval feedback: discard expansions whose retrieved sets diverge from the others.
- Keep a no-expansion path and A/B compare against it.

**Relevant work**

- Zhang et al., 2025, *LevelRAG* — treats query rewriting as a general planning layer decoupled from any single retriever. For Cake, this suggests a "retrieval planner" abstraction: one module performs query decomposition and expansion, then routes sub-queries across hybrid retrievers.
- Pan et al., 2025, *LLM-QE* — LLM-based query expansion using a Gaussian-kernel semantic space to refine multiple expansion vectors for dense retrieval. A future research direction rather than an MVP feature; a simplified multi-embedding expansion mode could follow later.
- Zhang et al., 2024, *Exploring Best Practices of Query Expansion with LLMs for IR* — systematic study showing that query expansion helps weaker retrievers most; strong dense models already perform some semantic expansion implicitly. For Cake, expansion should be optional and primarily valuable for tenants using cheaper embedding models.

**Open questions**

- Evaluate per tenant whether query expansion helps, using small offline tests.
- Investigate retrieval-based expansion (Olivera, 2025), where expansions are themselves retrieved and re-scored.

---

## 2. Chunking

Chunking determines how raw documents are divided into embedding units. Recent literature indicates that chunking strategy alone can move recall by five to ten percentage points on realistic RAG tasks.

**Relevance to Cake.** As a framework, Cake should treat chunkers as pluggable strategies with:

- Sensible defaults (recursive character, semantic, metadata-aware).
- Domain-specific presets (PDF reports vs. tickets vs. code).
- Evaluation harnesses, so tenants can measure how chunking changes retrieval.

### 2.1 Semantic Chunking

**What it is.** Segment documents using structure and semantics — headings, paragraphs, list boundaries, or LLM-based segmenters — rather than fixed-size windows.

**Benefits**

- Chunks are more likely to be self-contained enough to answer a question.
- Fewer concepts cut mid-thought at chunk boundaries.
- Better suited to long enterprise documents (policies, SOPs, contracts).

**Trade-offs**

- Requires more sophisticated ingestion and robust parsing.
- Poorly structured PDF/HTML can defeat structural cues.
- LLM-based segmentation adds latency and cost.

**Mitigations**

- Apply inexpensive deterministic rules first (headings, sections); fall back to LLM chunking only for unstructured documents.
- Cache LLM and multimodal chunking results aggressively.
- Track chunk usefulness over time and refine heuristics accordingly.

**Relevant work**

- Chroma, 2024, *Evaluating Chunking Strategies for Retrieval* — rigorous comparison of chunking strategies using recall, precision, and IoU-style metrics; semantic and metadata-aware chunkers outperform naive ones, with open-source tooling. Cake could productise a comparable chunking evaluation lab — something few frameworks offer.
- Merola et al., 2025, *Evaluating Advanced Chunking Strategies for RAG* — compares late chunking with contextual retrieval; contextual retrieval preserves coherence at higher cost, late chunking is efficient but loses detail. Suggests a "contextual retrieval mode" as an advanced option for high-value tenants.
- Multimodal chunking for PDFs (2025) — uses multimodal models to handle tables, figures, and cross-page structure. Relevant for enterprises with heavy reporting output.

### 2.2 Overlapping Windows

**What it is.** Allow adjacent chunks to overlap so boundary regions appear in multiple chunks (e.g. 1,000-token chunks with 200-token overlap).

**Benefits**

- Reduces errors caused by a crucial sentence falling on a chunk boundary.
- Important for code, protocols, and step-wise procedures.
- Makes retrieval more tolerant of segmentation choices.

**Trade-offs**

- Increases index size and ingestion cost.
- Amplifies duplicates, adding retrieval redundancy.
- More noise for downstream stages if the re-ranker or generator cannot filter it.

**Mitigations**

- Tune overlap per document type: larger for code, smaller for FAQs.
- Pair with deduplication at retrieval time, merging overlapping hits.
- Group related chunks during context assembly.

**Relevant work.** Recent chunking studies treat overlap as a tunable hyperparameter and find moderate overlap (10–30%) generally beneficial, with diminishing returns beyond that. For Cake: support per-index overlap configuration and ship profiles such as "long-form policy documents" (moderate overlap) and "code/API documentation" (higher overlap).

### 2.3 Multi-Representation Chunks

**What it is.** Store multiple embeddings per chunk, each capturing a different view: raw text, summary, extracted entities, or separate title and body embeddings. Also known as multi-vector embeddings.

**Benefits**

- Improves retrieval for entity-heavy queries (entity embedding) and conceptual queries (summary embedding).
- Different views can be weighted at query time.

**Trade-offs**

- Higher storage requirements.
- More complex retrieval logic.
- Harder index maintenance, with multiple vector fields per chunk.

**Mitigations**

- Start with two representations: the full chunk plus a summary or entity view.
- Use OpenSearch's support for multiple vector fields per document.
- Apply simple fusion rules per query type.

**Relevant work.** Industry reports show multi-vector retrieval yielding significant improvements on heterogeneous data, and RAG evolution reviews note that token-level and multi-vector representations are increasingly common for complex document structures. For Cake this is a genuine differentiator: offer a multi-representation schema as part of the ingestion configuration and let advanced users plug in their own summarisers and entity extractors.

**Open questions**

- Which combinations of representations give the best returns for enterprise knowledge bases (e.g. title + summary vs. summary + entities)?
- The results could support a short publication: *Multi-Representation Chunking for Enterprise RAG with OpenSearch*.

---

## 3. Context Assembly

Given a set of retrieved chunks, context assembly decides what is sent to the LLM and in what form: removing duplicates, grouping related chunks, and annotating their roles. This stage has a large effect on hallucination rates and coherence, particularly with long contexts.

**Relevance to Cake.** Most frameworks treat context assembly as an afterthought. Cake can make it a first-class pipeline stage: a context builder that is pluggable per tenant, with built-in strategies ranging from simple top-k through grouping by document, section, or role.

### 3.1 Deduplication and Consolidation

**What it is.** *Deduplication* removes near-identical chunks (identical text or high cosine similarity). *Consolidation* merges related chunks into concise summaries before they reach the LLM.

**Benefits**

- Less wasted context budget.
- Fewer conflicting statements in context.
- More grounded, concise answers.

**Trade-offs**

- Summarisation can itself hallucinate or drop critical detail.
- Consolidation adds latency.
- Citation tracking becomes more involved.

**Mitigations**

- Prefer extractive summaries (selecting key sentences) over abstractive rewrites.
- Restrict consolidation to chunks from the same document or section.
- Retain links to all source chunk IDs for citation purposes.

**Relevant work.** RAG best-practice guides consistently note that passing the top-N chunks verbatim is suboptimal; several employ post-retrieval clustering plus summarisation. For Cake: implement a document-level context builder (retrieve → cluster by document → summarise per document), and add a strict mode that uses only exact, unconsolidated chunks for high-risk queries.

### 3.2 Section-Aware Assembly

**What it is.** Group chunks by document section (e.g. "Section 3: Billing Disputes") or by conceptual role (background, constraints, examples), and present that structure to the LLM.

**Benefits**

- Labelled groupings reduce context confusion.
- Effective for multi-document answers ("Policy A says X; Policy B says Y").
- Supports multi-hop reasoning by making each chunk's role explicit.

**Trade-offs**

- Depends on good metadata at ingestion (headings, hierarchy).
- Not all corpora have clean structure (ticket logs, chat transcripts).
- Prompt construction becomes more complex.

**Mitigations**

- For unstructured data, use simple heuristics (source, date, document type) as pseudo-sections.
- Provide default prompt scaffolds for sectioned context.

**Relevant work.** Community and enterprise guidance shows that sectioned context improves RAG QA quality. For Cake: include a section-aware context template as a core feature, and expose structured prompts where context is passed as, for example, `{definitions: [], procedures: [], examples: []}`.

### 3.3 Role-Annotated Context

**What it is.** Assign roles to chunks — facts, definitions, constraints, examples, user history — and instruct the LLM how to use them (e.g. "prioritise constraints over examples when they conflict").

**Benefits**

- More deterministic, policy-compliant answers.
- Predictable conflict handling (policy vs. example).
- A good fit for enterprise compliance and SOP workflows.

**Trade-offs**

- Requires chunk classification, whether manual or model-based.
- More complex prompts and context construction.

**Mitigations**

- Start with simple roles derived from metadata or heuristics (title, path).
- Add optional LLM-based role classification as an offline pipeline.

**Relevant work.** Role-annotated context is an emerging pattern in enterprise RAG literature, motivated by auditability and consistency, rather than the subject of dedicated academic study. For Cake: make role tagging an optional ingestion stage, and at minimum always distinguish source documents, retrieval logs, and conversation memory.

---

## 4. Augmented Generation

Rather than passing context to the LLM with a bare "answer this", augmented generation structures the reasoning process: retrieve, reason over the evidence, then answer — sometimes with explicit intermediate artifacts (plans, chains, scratchpads). This reduces hallucination and produces better-grounded explanations.

**Relevance to Cake.** For Cake to be more than "LangChain in Elixir", generation pipeline templates are a key differentiator — "strict QA", "summarise across documents", "decision memo" — each a procedural template for reasoning, not merely a prompt.

### 4.1 Contextual Reasoning Chains

**What it is.** The LLM explicitly generates intermediate reasoning steps over the retrieved evidence: extract key facts from each chunk, combine and reconcile them, then produce a final answer with citations.

**Benefits**

- Better faithfulness and easier debugging.
- Reasoning patterns can be reused across queries.
- Intermediate steps are themselves evaluable, which suits automated evaluation tooling.

**Trade-offs**

- More tokens and higher latency.
- Unconstrained chain-of-thought can introduce its own hallucinations.

**Mitigations**

- Keep reasoning steps short and largely extractive ("list the relevant facts from the context").
- Hide intermediate reasoning from end users while logging it for internal evaluation.
- Instruct explicitly: use only facts from the context, quoting where possible.

**Relevant work.** Recent RAG evaluation efforts (FRAMES, ARES, and others) implicitly assume multi-step reasoning patterns. For Cake: offer stock reasoning templates such as "evidence extraction" and "compare and contrast two policies", and log intermediate reasoning for analytics on where answers go wrong.

### 4.2 Retrieval-Augmented Planning

**What it is.** The LLM first plans the steps required to answer — including what to retrieve — then executes the plan, often over multiple retrieval iterations.

**Benefits**

- Essential for multi-hop and complex workflows (e.g. "find all policies affected by regulation X and summarise the changes since 2022").
- Different retrievers can serve different sub-queries.

**Trade-offs**

- More complex architecture (agents, tools).
- Easy to over-engineer, with significant latency cost.

**Mitigations**

- Restrict plans to two or three stages rather than free-form agent loops.
- Use a coarse retrieval planner that decides query decomposition and index routing.

**Relevant work**

- Zhang et al., 2025, *LevelRAG* — a high-level searcher coordinating multiple low-level searchers via query decomposition.
- Verma et al., 2025, *PLAN-RAG: Planning-guided Retrieval Augmented Generation* — matches the plan-then-retrieve paradigm.
- Work on question decomposition with cross-encoder re-ranking further supports staged, planned retrieval.

For Cake: make the retrieval plan an explicit data structure in the pipeline rather than hidden prompt text, and keep the pipeline modular enough to add a planner stage later. Eventually, advanced users could supply simple planners (in Elixir) that choose retrieval strategy by question type.

---

## 5. Guardrails and Faithfulness

This area covers preventing and detecting hallucinations and unfaithful answers — critical in enterprise settings, where a plausible-sounding but wrong answer carries real cost.

**Relevance to Cake.** Enterprise adoption requires a credible trust story: faithfulness checks, citation quality, and monitoring of hallucination rates over time.

### 5.1 Faithfulness Checks

**What it is.** Post-hoc or in-loop verification that an answer is supported by the retrieved context: NLI-style entailment models, LLM-as-judge scoring, or metamorphic tests (perturb the inputs and check that the answer changes sensibly).

**Benefits**

- Catches egregious hallucinations.
- Can emit confidence scores or route answers to human review.

**Trade-offs**

- Additional models and cost.
- Judgments are noisy, particularly across domains.

**Mitigations**

- Use binary safe/unsafe thresholds rather than assuming precise calibration is achievable.
- Start with LLM-as-judge using a simple faithful/unfaithful prompt against the citations.
- Reserve heavier checks for high-risk tenants and queries.

**Relevant work**

- FaithJudge and the Vectara hallucination leaderboards (2025) — benchmark RAG faithfulness via LLM-as-judge.
- Wallat et al., 2025, *Correctness is Not Faithfulness in RAG* — demonstrates that a correct citation is insufficient; the citation must actually ground the answer.
- MetaRAG (2025) — a metamorphic testing framework for hallucination detection in production RAG systems where gold labels are unavailable.

For Cake: short term, a simple faithfulness scorer using LLM-as-judge over the retrieved context; longer term, metamorphic tests integrated into the evaluation suite.

### 5.2 Citation Mode

**What it is.** Require the model to emit inline citations tied to retrieved chunks (e.g. `[1]`, `[2]`), mapped to document IDs and URLs.

**Benefits**

- Increases user trust.
- Enables automated evaluation of citation correctness and faithfulness.
- Encourages more grounded responses.

**Trade-offs**

- Models can mis-attribute citations.
- Formatting is fiddly and the UX must accommodate it.

**Mitigations**

- Post-process citations (in the style of CiteFix) rather than trusting raw model output.
- Evaluate citation correctness; repair or drop incorrect citations.

**Relevant work**

- CiteFix (2025) — post-processing that improves citation accuracy at minimal cost.
- RAGE and related work — citation metrics for evaluating and tuning RAG systems.

For Cake: make citations mandatory for factual QA modes; build a generic citation data model (`chunk_id`, `char_span`, `doc_url`); and let tenant UIs style citations as they see fit.

---

## 6. Structured and Domain-Aware Retrieval

This area moves beyond treating documents as bags of words, exploiting schemas, graphs, and domain structure: tables, APIs, CRM objects, product hierarchies, and knowledge graphs.

**Relevance to Cake.** This is where Cake can evolve from "RAG framework" toward "RAG substrate for enterprise systems". Enterprises already have schemas and graphs; Cake needs to plug into them.

### 6.1 Schema-Aware Retrieval

**What it is.** Use domain schemas (tables, JSON, code, API descriptions) to retrieve structured records rather than only text, embed both text and schema metadata, and let the LLM reason over structured and unstructured evidence together.

**Benefits**

- Better performance when the answer lives in a database or API rather than a document.
- Reads current data instead of stale document snapshots.

**Trade-offs**

- Requires connectors and schema mapping.
- Some LLMs handle complex structured prompts poorly.

**Mitigations**

- Combine structured queries (SQL, filters) with text search.
- Summarise structured outputs into LLM-friendly snippets.

**Relevant work.** Cheerla et al., 2025, *Advancing RAG for Structured and Semi-Structured Data* — hybrid retrieval combining BM25, dense retrieval, and metadata-aware filtering over structured data. For Cake: define a schema ingestion interface so that, given a table or API, Cake can build metadata-aware filters and join structured results with text context.

### 6.2 Graph-Augmented Retrieval

**What it is.** Use a knowledge graph — pre-existing or derived from text — to expand retrieval via neighbours, organise context around entity and relationship paths, and guide multi-hop reasoning.

**Benefits**

- Better coverage of related facts.
- More coherent long-form answers.
- Particularly effective in complex domains (biomedical, legal, enterprise organisations).

**Trade-offs**

- Building and maintaining knowledge graphs is expensive.
- Graph operations add latency.
- The graph must be kept in sync with the underlying text.

**Mitigations**

- Generate a lightweight graph from documents (entities plus document IDs).
- Link chunks to graph nodes.
- Engage the graph selectively, for multi-hop and cross-document query types.

**Relevant work**

- Zhu et al., 2025, *KG²RAG* — semantic retrieval, then knowledge-graph-guided expansion and organisation into paragraphs for RAG.
- Liu et al., 2025, *GGR* — GNN-guided KG-RAG that preserves key reasoning paths.
- GraphRAG and related enterprise deployments report substantial gains on cross-document reasoning.

For Cake: do not attempt full GraphRAG in v1. Instead, provide hooks for tenants who already have graphs, and offer a basic document-derived graph (entities, document IDs, links).

### 6.3 Vocabulary Steering

**What it is.** Use logit bias or vocabulary steering so the model prefers domain-specific terms present in the context and avoids generic substitutions (e.g. "employee handbook" rather than "staff manual").

**Benefits**

- More consistent terminology.
- Less generic, hallucination-prone phrasing.
- Useful for brand names, product names, and internal acronyms.

**Trade-offs**

- Logit bias APIs are model-specific.
- Misconfiguration can produce degenerate output.

**Mitigations**

- Apply bias only to a small, curated term list per tenant.
- Keep bias magnitudes modest and test thoroughly.

**Relevant work.** This is established practice rather than formal research; enterprise RAG whitepapers describe vocabulary steering for brand-safe output. For Cake: offer a preferred-vocabulary configuration at tenant level, and later auto-suggest vocabulary lists from the tenant's corpus.

---

## 7. Conversational Memory

Multi-turn RAG requires tracking what has been said, what has been retrieved, and what the user cares about over time.

**Relevance to Cake.** Cake's Elixir/OTP foundations suit this naturally: a conversation is a stateful process, not a stateless question-answer exchange. This is an area where Cake can outperform.

### 7.1 Conversation-Aware Retrieval

**What it is.** Embed conversation turns and use them as additional retrieval signals (the conversation has been about VPNs, not HR) and to disambiguate pronouns and references. This constitutes the conversation's short-term memory.

**Benefits**

- Better contextual relevance.
- Fewer repeated clarification requests.

**Trade-offs**

- Memory grows over time, and retrieval over it becomes expensive.
- Risk of retrieving outdated context, such as superseded answers.

**Mitigations**

- Bound short-term memory: the last N turns plus a running summary.
- Summarise older turns.

**Relevant work.** Surveys of RAG-driven memory architectures (2025) and multi-turn benchmarks such as MTRAG evaluate multi-turn retrieval and reasoning directly. For Cake: provide a built-in conversation memory store and retrieval hook, separate from the main knowledge base, with tenant-tunable memory length and summarisation strategy.

### 7.2 Long-Term Memory

**What it is.** Persist distilled facts about the user or an ongoing task — preferences, company-specific decisions, prior agreements — as structured objects or summarised notes.

**Benefits**

- Supports long-lived workflows and agents.
- Avoids re-asking questions already answered.

**Trade-offs**

- Risk of persisting incorrect information.
- Stored facts can conflict with newer knowledge-base content.

**Mitigations**

- Attach timestamps and confidence levels to stored facts.
- Periodically reconcile memory against authoritative sources.

**Relevant work.** Long-term memory is covered by conversational memory surveys and multi-turn RAG evaluation work. For Cake: offer a long-term memory interface — a simple key-value or fact-graph store, with LLM helpers that update it conservatively.

### 7.3 Multi-Turn Reference Disambiguation

**What it is.** Resolve pronouns and shorthand across turns: "that policy" → which policy? "the second option you mentioned" → which chunk or document?

**Benefits**

- Critical for enterprise conversational UX.
- Reduces misinterpretation.

**Trade-offs**

- Requires either LLM-based resolution over recent turns or a graph of mentions and their bindings.

**Mitigations**

- Use a small coreference resolver over recent turns.
- Use retrieval over conversation memory to find the most recently discussed entity.

**Relevant work.** Multi-turn benchmarks such as MTRAG (2025) centre on QA where context tracking is essential. For Cake: make reference resolution an explicit pipeline step that rewrites the raw user query into a fully de-referenced query.

---

## 8. Evaluation and Feedback Loops

Evaluation cannot be an afterthought. Production RAG requires constant measurement of retrieval quality, generation faithfulness, and drift over time.

**Relevance to Cake.** First-class RAG evaluation tooling is a major potential differentiator, against the status quo of ad-hoc dashboards assembled per deployment.

### 8.1 Synthetic Query Evaluation

**What it is.** Use LLMs to generate synthetic queries, answers, and sometimes labels from the corpus, then evaluate retrieval and generation performance against them.

**Benefits**

- Builds evaluation sets cheaply, without full human labelling.
- Enables rapid comparison of chunking and retrieval configurations.
- Supports automated acceptance checks before deploying changes.

**Trade-offs**

- Synthetic queries may not match the real user distribution.
- LLM-generated answers can be wrong, polluting the labels.

**Mitigations**

- Mix in a small human-validated subset.
- Use LLM-as-judge for scoring, not as ground truth.

**Relevant work**

- Saad-Falcon et al., 2024, *ARES* — automated RAG evaluation using synthetic queries and LLM judges.
- FRAMES (2024) — a unified dataset for evaluating factuality, retrieval, and reasoning in RAG.
- Synthetic test collections for IR (2024) — fully synthetic IR benchmarks built with LLMs.

For Cake: build a synthetic evaluation kit — given a corpus, auto-generate 100–500 synthetic queries and answers, run them through different Cake pipelines, and report recall, precision, and faithfulness metrics.

### 8.2 Drift Detection

**What it is.** Monitor change over time: *data drift* (new documents, updated policies), *concept drift* (query meanings shift), and *model drift* (new model versions behave differently).

**Benefits**

- Prevents silent degradation.
- Gives enterprises confidence that failures will be detected.

**Trade-offs**

- Non-trivial to implement, and the metrics can be fuzzy.
- Requires historical logs, not just snapshots.

**Mitigations**

- Track simple KPIs: context recall, answer faithfulness, user feedback rates.
- Alert on significant deltas.

**Relevant work.** Industry material on retrieval drift monitoring and concept-drift adaptation, and RAG evaluation literature emphasising continuous monitoring in production. For Cake: incorporate drift dashboards at the framework level — per corpus, per tenant, and before/after model version changes.

---

## Recommendations

This section translates the survey into practice: what to build now, what to adjust in the MVP design, and where Cake can establish an early edge.

### A. Immediate Priorities

1. **Lock in retrieval as a configurable pipeline.**
   - Implement hybrid retrieval in OpenSearch: BM25 + dense, or neural sparse + dense, with tunable weights.
   - Add a simple re-ranker, starting with a small cross-encoder on CPU or inexpensive GPU.
   - Add optional query expansion, starting with HyDE-style hypothetical-answer embedding.

2. **Chunking v1.5: metadata-aware, with overlap.**
   - Implement metadata-aware semantic chunking using headings and sections where available.
   - Support configurable overlap per index.
   - Store basic metadata: `doc_id`, `section_title`, `page`, and similar fields.

3. **Context builder abstraction.**
   - Extract a formal `ContextBuilder` from the current pipeline: deduplicate hits, group by document, attach metadata and roles.
   - Provide two strategies initially: simple top-k raw chunks, and grouped-by-document with basic summarisation.

4. **Citations and logging.**
   - Add a mandatory citation mode for factual QA paths.
   - Log retrieved chunk IDs, citations used, and basic LLM-as-judge faithfulness scores.

5. **Basic evaluation harness.**
   - Implement a small ARES-inspired workflow: synthetic queries generated from the corpus, scored for relevance and faithfulness by LLM-as-judge.

Together these are enough to position Cake as a serious framework rather than a do-it-yourself assembly of parts.

### B. MVP Design Changes

None of this requires a rewrite, but a few structural decisions matter now:

- **Make pipelines first-class.** Represent retrieval and generation as structured Elixir pipelines — `query_normalize → planner (optional) → retriever(s) → reranker → context_builder → generator → guardrails` — with configurations stored declaratively (YAML/JSON) so tenants can define pipelines without code.
- **Design the document schema for multi-representation.** Even before it is fully exploited, define the OpenSearch schema to allow multiple vector fields (raw, summary, entities) and rich metadata, avoiding migration pain later.
- **Split memory from the knowledge base.** Keep conversational memory in a separate index or store from the main corpus, with a clean API boundary between conversation-memory retrieval and corpus retrieval.

### C. Scaling Considerations

For high-touch enterprise implementations, the following matter most:

- **Configurable retrieval recipes.** Each customer will need slightly different hybrid weights, chunking strategy, and re-ranking depth. These must be adjustable in configuration, not code.
- **Evaluation and monitoring built in.** Shipping with a synthetic evaluation harness, faithfulness scoring, and drift dashboard hooks supports the pitch that Cake does not just build a RAG system but monitors and tunes it over time.
- **Hooks for structure.** Full graph-augmented retrieval is not needed on day one, but the extension points for graph-based retrieval and for ingesting SQL/NoSQL tables with domain-aware filters should exist early.

### D. Early Differentiators

1. **Multi-representation chunking as a first-class feature.** Most tools still treat a chunk as a single embedding. Cake can define a multi-vector document schema and provide stock pipelines for combining representations — a natural fit for its schema-design and OpenSearch strengths.
2. **A built-in chunking evaluation lab.** Almost no framework productises Chroma-style chunking evaluation. Cake could let a customer upload a corpus, try three or four chunking configurations, and compare metrics and example queries side by side.
3. **Conversation-aware enterprise RAG.** Many products still treat every query as stateless. Cake can bake in short-term memory embeddings, basic long-term memory, and multi-turn evaluation in the style of MTRAG — positioning Cake for ongoing knowledge work rather than single questions.
4. **Evaluation as part of the core story.** Building on ARES and FRAMES, make evaluation part of the standard Cake deployment: the pitch is measurement, not just construction.

### Risks

- **Over-engineering early.** The research directions above (LevelRAG-style planning, graph retrieval, advanced query expansion) are tempting, but the priority is a sellable v1, not a research platform. *Mitigation:* ship hybrid retrieval, re-ranking, semantic chunking, citations, and basic evaluation first; everything else is explicitly Phase 2.
- **Scope creep through perfectionism.** The MVP does not need to be state-of-the-art across all eight areas to be viable. *Mitigation:* define a hard MVP threshold — hybrid retrieval, semantic chunking, citations, basic synthetic evaluation — and treat anything beyond it as explicit backlog rather than an implicit requirement.
