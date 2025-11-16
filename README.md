# Table of Contents
- [1. Retrieval](#1-retrieval-because-naive-vector-search-is-mid)
  - [1.1 Hybrid Search](#11-hybrid-search)
  - [1.2 Re-ranking Pipelines](#12-re-ranking)
  - [1.3 Query Expansion](#13-query-expansion)
- [2. Chunking](#2-chunking)
  - [2.1 Semantic Chunking](#21-semantic-chunking)
  - [2.2 Overlapping Windows](#22-overlapping-windows)
  - [2.3 Multi-Representation Chunks](#23-multi-representation-chunks)
- [3. Context Assembly](#3-context-assembly)
  - [3.1 Deduplication & Consolidation](#31-deduplication--consolidation)
  - [3.2 Section-Aware Assembly](#32-section-aware-assembly)
  - [3.3 Role-Based Context Windows](#33-role-based-context-windows)
- [4. Augmented Generation](#4-augmented-generation)
  - [4.1 Contextual Reasoning Chains](#41-contextual-reasoning-chains)
  - [4.2 Retrieval-Augmented Planning](#42-retrieval-augmented-planning)
- [5. Guardrails & Faithfulness](#5-guardrails--faithfulness)
  - [5.1 Faithfulness Checks](#51-faithfulness-checks)
  - [5.2 Citation Mode](#52-citation-mode)
- [6. Domain/Structured Retrieval](#6-domainstructured-retrieval)
  - [6.1 Schema-Aware Retrieval](#61-schema-aware-retrieval)
  - [6.2 Graph-Augmented Retrieval](#62-graph-augmented-retrieval)
  - [6.3 Logit Bias](#63-logit-bias)
- [7. Conversational Memory](#7-conversational-memory)
  - [7.1 Short-Term Memory Embeddings](#71-short-term-memory-embeddings)
  - [7.2 Long-Term Memory](#72-long-term-memory)
  - [7.3 Multi-Turn Reference Disambiguation](#73-multi-turn-reference-disambiguation)
- [8. Evaluation & Feedback](#8-evaluation--feedback-loops)
  - [8.1 Synthetic Query Testing](#81-synthetic-queries-for-recall-testing)
  - [8.2 Drift Detection](#82-drift-detection-for-content-updates)
- [CAQue Recommendations](#recommendations-for-caqueue)
  - [A. Immediate Priorities](#a-immediate-priorities-next-mvp-iterations)
  - [B. Changes to the MVP Design](#b-changes-to-the-mvp-design)
  - [C. Most Relevant to Scaling CAQue](#c-most-relevant-to-scaling-caqueue)
  - [D. Competitive Advantages](#d-potential-competitive-advantages-to-seize-early)

#RAG Enhancements

## 1. Retrieval (because naive vector search is mid)

#### What this class is  
This covers how you *select candidate chunks* from the corpus before the LLM sees anything. If retrieval sucks, nothing downstream fixes it. Hybrid search, re-ranking, and query expansion are three levers to boost recall *and* precision beyond “cosine similarity on a single embedding.”

In real RAG systems, retrieval is often 70–80% of the quality story. :contentReference[oaicite:0]{index=0}

#### Relevance to CAQue  
CAQue is meant to be a **framework**, not just a toy app. That means your retrieval layer has to be:
- **Configurable** (per-tenant / per-domain retrieval recipes)  
- **Composable** (query → retrieve → re-rank → post-filter)  
- **Observable** (you can see *why* a query failed)  

Hybrid, reranking, and query expansion should be **first-class pipeline stages** CAQue exposes.

---

#### 1.1 Hybrid Search  
**What it is**  
Combine **sparse** (BM25 / neural sparse) and **dense** (embeddings) retrieval into one ranked list. Either via score fusion (e.g., weighted sum) or multi-stage (BM25 → dense filter or vice-versa). :contentReference[oaicite:1]{index=1}  

**Pros**  
- Much better robustness on:  
  - rare terms, IDs, codes (sparse)  
  - paraphrases and fuzzy language (dense)  
- Works well on **enterprise KBs** that mix jargon with natural language.  
- Plays nicely with OpenSearch (you already get BM25 + dense + neural sparse).  

**Cons**  
- Score fusion is fiddly (how to weight sparse vs dense).  
- Latency and infra complexity (multiple retrievers).  
- Can over-emphasize long docs or spammy fields if BM25 isn’t tuned.  

**Mitigations**  
- Learn weights per index or per tenant (simple grid search or small regression model).  
- Normalize scores (z-score or min–max per retriever).  
- Use **metadata filters** and field-specific boosts to keep BM25 sane (e.g., title > body).  

**Recent work & CAQue angle**  
- [Wang et al., 2024] *“Searching for Best Practices in Retrieval-Augmented Generation”* – looks at combinations of retrieval strategies. :contentReference[oaicite:2]{index=2}  
  - *Goal*: Benchmark many RAG configs (retrievers, chunking, reranking)  
  - *Practicality*: Very high (off-the-shelf setups)  
  - *Future*: More adaptive hybrids (e.g., dynamic weighting per query)  
  - *For CAQue*: Treat their recommended “Hybrid + HyDE” recipe as a **default retrieval preset**.  
- [Zhang et al., 2025] *“LevelRAG: Enhancing Retrieval-Augmented Generation with Multi-hop Logic Planning over Rewriting Augmented Searchers”* – hybrid + multi-searchers. :contentReference[oaicite:3]{index=3}  
  - *Goal*: Decompose complex queries into atomic subqueries, independent of retriever-specific optimization.  
  - *Practicality*: Moderate-high for enterprises that have graphs or can derive them.  
  - *For CAQue*: Aligns strongly with a **“structured retrieval preset”**: graph + dense + rerank.  

**Independent research ideas**  
- Learn **per-tenant fusion weights** from minimal feedback (clicks / thumbs up/down).  
- Evaluate whether **OpenSearch neural sparse + dense** beats classic BM25 + dense for the specific enterprise domains you target, and publish that as a “CAQue Retrieval Study”.

---

#### 1.2 Re-ranking Pipelines  
**What it is**  
Two-stage retrieval: first get a big candidate pool (e.g. top-50 or top-100 chunks), then score each candidate more precisely with a **cross encoder** or LLM-as-reranker, producing a much better top-5.

**Pros**  
- Huge quality bump, especially in noisy KBs (duplicate docs, irrelevant boilerplate).  
- You can keep recall high while controlling **LLM context size**.  
- Great in high-stakes domains (compliance, finance, medical).  

**Cons**  
- Extra latency (heavy model scoring 50–100 candidates).  
- Additional infra complexity (GPU/CPU serving, batching, caching).  
- If your baseline retrieval is garbage, reranking can’t fix it.  

**Mitigations**  
- Use efficient cross encoders (e.g., MiniLM, MPNet) and **batch across tenants**.  
- Cache reranker scores for repeated queries or canonical question templates.  
- Use **adaptive candidate set sizes** (k=30 for short queries, k=100 for multi-hop).  

**Recent work & CAQue angle**  
- [Zhu et al., 2025] *KG²RAG* – semantic retrieval + KG-guided organization + reranking; uses cross-encoders.  
  - *Goal*: Improve coherence and relevance by using KG structure plus reranking.  
  - *For CAQue*: Enables “graph-aware rerankers” as an advanced option.  
- Industry write-ups (Pinecone, Databricks, blogs) show reranking as one of the simplest big wins.

**Independent research ideas**  
- Re-rank **not just chunks but chunk-groups** (e.g., all chunks from the same doc or section).  
- Use **multi-objective reranking** for enterprise: relevance + recency + access control.

---

#### 1.3 Query Expansion  
**What it is**  
Automatically expand or rewrite a user query into richer representations: paraphrases, related terms, or synthetic “ideal answers” whose content you then retrieve against. Includes HyDE-style (“generate a hypothetical answer, embed that”) and LLM-based query expansion variants.

**Pros**  
- Fixes short or vague queries (“VPN broken”, “hr policy maternity”).  
- Bridges lexical gaps (synonyms, abbreviations, multilingual).  
- Especially strong when combined with hybrid retrieval.  

**Cons**  
- Can introduce **drift** if expansions hallucinate irrelevant concepts.  
- High compute if you generate many expansions per query.  
- Can hurt precision by pulling in tangential docs.  

**Mitigations**  
- Limit to **2–3 expansions** and keep them short.  
- Use **retrieval feedback**: discard expansions whose retrieved set has low similarity to others.  
- Add a “no expansion” path and AB compare.  

**Recent work & CAQue angle**  
- [Zhang et al., 2025] *LevelRAG* – query rewriting decoupled from any single retriever. :contentReference[oaicite:4]{index=4}  
  - *Goal*: Make query rewriting a general planning layer, not hard-tied to dense retrievers.  
  - *For CAQue*: Use as your **“retrieval planner”** abstraction: one module does query decomposition/expansion, and then routes sub-queries across hybrid retrievers.  
- [Zhang et al., 2024] *“Exploring Best Practices of Query Expansion with LLMs for IR”* – systematic study of LLM-based query expansion. :contentReference[oaicite:5]{index=5}  
  - *Takeaway*: QE helps *weaker* retrievers more; strong dense models already do some semantic expansion.  
  - *For CAQue*: Make QE **optional** and mostly useful when tenants use cheaper embeddings.  

**Independent research ideas**  
- Evaluate **per-tenant** whether QE helps (small offline tests).  
- Try **RAG-based QE** (as in Olivera 2025) where expansions are themselves retrieved and re-scored.

---

## 2. Chunking

#### What this class is  
Chunking is how you cut raw docs into embedding units. The literature is loud now: **chunking strategy can easily swing recall by ~5–10 percentage points** for real RAG tasks.

#### Relevance to CAQue  
CAQue as a framework should treat **chunkers as pluggable strategies** with:
- Defaults (recursive char, semantic, metadata-aware)  
- Domain-specific presets (PDF reports vs tickets vs code)  
- Evaluation harnesses (so tenants can *see* how chunking changes retrieval)

---

#### 2.1 Semantic Chunking  
**What it is**  
Use document structure and semantics (headings, paragraphs, list boundaries, LLM segmenters) instead of dumb “every 512 chars.”

**Pros**  
- Higher chance that a chunk is **self-contained enough** to answer a question.  
- Fewer “cut in the middle of a concept” issues.  
- Better for long enterprise docs (policies, SOPs, contracts).

**Cons**  
- More complex ingestion (you need robust parsing).  
- PDF/HTML soup can break structural cues.  
- Latency/cost if you use an LLM for segmentation.  

**Mitigations**  
- Use **cheap deterministic rules** first (headings, sections) and only fallback to LLM chunking for ugly docs.  
- Cache multimodal chunk results aggressively.  
- Log “chunk usefulness” over time and refine heuristics.

**Recent work & CAQue angle**  
- *Chroma “Evaluating Chunking Strategies for Retrieval” (2024)* – rigorous analysis of chunking strategies using Recall, Precision, IoU-style metrics.  
  - *For CAQue*: Build a **chunking-eval lab** similar to Chroma’s.  
- *“Evaluating Advanced Chunking Strategies for RAG” (Merola et al., 2025)* – compares late chunking vs contextual retrieval.  
  - *For CAQue*: Suggest a **“contextual retrieval mode”** as advanced option.  
- *Multimodal chunking for PDFs (2025)* – uses LLMs/vision to handle tables, figures.  
  - *Future*: Important for enterprises with heavy reporting.

---

#### 2.2 Overlapping Windows  
**What it is**  
Allow chunks to overlap so that boundary regions appear in multiple chunks (e.g., 1k tokens with 200-token overlap).

**Pros**  
- Reduces “I cut out the crucial sentence” errors.  
- Essential for code, protocols, step-wise procedures.  
- Makes retrieval more tolerant to segmentation choices.

**Cons**  
- Increases index size and ingest cost.  
- Can amplify duplicates leading to retrieval redundancy.  
- More noise if reranker/generator isn’t smart.

**Mitigations**  
- Tune overlap per doc type (large for code, small for FAQs).  
- Combine with **deduplication** in retrieval (merge overlapping hits).  
- Use chunk grouping at context-assembly time.

**Recent work & CAQue angle**  
Most recent chunking studies treat overlap as a tunable hyperparameter and show moderate overlap (10-30%) is generally beneficial.  
For CAQue:  
- Allow **per-index overlap configuration**.  
- Provide “profiles” like: “Long-form policy docs” (moderate overlap) and “Code/API docs” (higher overlap).

---

#### 2.3 Multi-Representation Chunks  
**What it is**  
Store **multiple embeddings per chunk**, each capturing a different aspect: raw text, summary, entities, maybe separate embeddings for title vs body. Sometimes called **multi-vector embeddings**.

**Pros**  
- Better retrieval for:  
  - Entity-heavy queries (use NER embedding)  
  - Conceptual queries (use summary embedding)  
- Allows you to weight different views at query time.

**Cons**  
- More storage.  
- More complex retrieval logic.  
- Index maintenance is harder (multiple fields per chunk).

**Mitigations**  
- Start with just **two representations**: full chunk and summary/entities.  
- Use OpenSearch’s support for multiple vector fields per document.  
- Use **simple fusion rules** per query type.

**Recent work & CAQue angle**  
- Industry write-ups (Baobab, AI Edge, vector DB blogs) show multi-vector yielding significant improvements.  
  - *For CAQue*: This is a **killer differentiator**: offer a **multi-representation schema** as part of the ingestion config and let advanced users plug in their own summarizers/NERs.  
- Independent research:  
  - Perform studies on **which combos of representations** give best returns for enterprise KBs (e.g., title + summary vs summary + entities).  
  - Build a small paper: “Multi-Representation Chunking for Enterprise RAG with OpenSearch”.

---

## 3. Context Assembly

#### What this class is  
You’ve got a set of retrieved chunks. Now you decide **what to send to the LLM** and **how**. Context assembly is about:  
- Removing duplicates  
- Grouping related chunks  
- Annotating their roles  
This is hugely impactful for **hallucinations and coherence**, especially on long contexts.

#### Relevance to CAQue  
Most frameworks treat this as an afterthought. You can make it a **first-class pipeline stage**:  
- A “context builder” that’s pluggable per tenant.  
- Built-in strategies: simple top-k, grouped by document, grouped by section/role, etc.

---

#### 3.1 Deduplication and Consolidation  
**What it is**  
- **Deduplication**: removing near-identical chunks (same text, or high cosine sim).  
- **Consolidation**: merging multiple related chunks into concise summaries *before* sending to the LLM.

**Pros**  
- Less wasted context budget.  
- Reduces conflicting statements.  
- Makes answers more grounded and concise.

**Cons**  
- Summarization can itself hallucinate or drop critical detail.  
- Extra latency for consolidation step.  
- Requires careful citation tracking.

**Mitigations**  
- Use **extractive summaries** where possible (pull key sentences instead of abstractive).  
- Limit consolidation to chunks from the same doc/section.  
- Keep links back to all source chunk IDs for citations.

**Recent work & CAQue angle**  
Most RAG best-practice guides emphasize that naive “dump top N chunks as-is” is suboptimal.  
For CAQue:  
- Implement a **document-level context builder**: retrieve chunks → cluster by doc → summarise per doc.  
- Add a “strict mode” where only exact chunks (no summarisation) are used for high-risk queries.

---

#### 3.2 Section-aware Assembly  
**What it is**  
Group chunks by document sections (e.g., “Section 3: Billing Disputes”) or conceptual “sections” (background, constraints, examples), and feed this structured context to the LLM.

**Pros**  
- Reduces context confusion by giving the model **labeled buckets**.  
- Works well for multi-doc answers (“Policy A says X, Policy B says Y”).  
- Helps multi-hop reasoning—model sees which chunk is doing what.

**Cons**  
- Requires good metadata at ingest (parse headings/hierarchy).  
- Not all corpora have clean structure (ticket logs, chat).  
- Prompts get more complex.

**Mitigations**  
- For unstructured data, use simple heuristics (source, date, doc type) as pseudo-sections.  
- Build default prompt scaffolds (“You are given multiple sections: …”).

**Recent work & CAQue angle**  
OpenAI community posts and enterprise guides show sectioned context improves RAG QA quality.  
For CAQue:  
- Include a **section-aware context template** as a core feature.  
- Expose structured prompts where you pass context as `{definitions:[], procedures:[], examples:[]}`.

---

#### 3.3 Context Windows with Roles  
**What it is**  
Assign roles to chunks: **facts**, **definitions**, **constraints**, **examples**, **user history**, etc., and instruct the LLM how to use them (e.g., “prioritise constraints over examples when conflicts occur”).

**Pros**  
- Makes answers more deterministic and policy-compliant.  
- Lets you handle conflicts (policy vs example) more predictably.  
- Good fit for enterprise compliance / SOP flows.

**Cons**  
- Requires classification of chunks (manual or model-based).  
- More complicated prompts and context-building.

**Mitigations**  
- Start with **simple roles** based on metadata or heuristics (title, path).  
- Add optional **LLM-based role classification** as offline pipeline.

**Recent work & CAQue angle**  
Less specific dedicated research, more an emerging pattern in enterprise RAG whitepapers (auditability, compliance).  
For CAQue:  
- Make “role tagging” an optional ingest pipeline stage.  
- At minimum: distinguish between **source docs**, **retrieval logs**, **conversation memory**.

---

## 4. Augmented Generation, not Raw Generation

#### What this class is  
Instead of “throw context at LLM and say ‘answer this’”, you structure the **reasoning process**:
- Retrieve → reason over evidence → then answer.
- Sometimes with explicit intermediate steps (plans, chains, scratch-pads).  
This reduces hallucinations and makes explanations more grounded.

#### Relevance to CAQue  
You want CAQue to be more than “LangChain in Elixir.” Generation pipeline templates are a key differentiator:
- “Strict QA”
- “Summarise across docs”
- “Decision memo”

All of them should be **procedural templates** for reasoning, not just prompts.

---

#### 4.1 Contextual Reasoning Chains  
**What it is**  
LLM explicitly generates **intermediate reasoning steps** over the retrieved evidence:  
1. Extract key facts from each chunk.  
2. Combine and reconcile facts.  
3. Produce final answer, citing sources.

**Pros**  
- Better faithfulness; easier to debug.  
- Can be reused across queries as a pattern.  
- Plays nicely with evaluation tools (you can evaluate intermediate steps).

**Cons**  
- More tokens and latency.  
- If not carefully constrained, chain-of-thought can hallucinate.

**Mitigations**  
- Keep reasoning steps short and almost **extractive** (“List relevant facts from the context”).  
- Hide chain-of-thought from end user while logging it for internal eval.  
- Put explicit instructions: “Only use facts from the context, quote them when possible.”

**Recent work & CAQue angle**  
Many recent RAG evaluations implicitly assume multi-step reasoning patterns.  
For CAQue:  
- Offer **stock reasoning templates**: “Evidence extraction,” “Compare & contrast two policies.”  
- CAQue can log intermediate reasoning for **analytics** (where did it go wrong?).

---

#### 4.2 Retrieval-augmented Planning  
**What it is**  
LLM first **plans the steps** required to answer (including what to retrieve), then executes those steps, often with multiple retrieval iterations.

**Pros**  
- Crucial for multi-hop or complex workflows (e.g., “find all policies impacted by regulation X and summarise changes since 2022”).  
- Lets you use different retrievers for different sub-queries.

**Cons**  
- More complicated architecture (agents, tools).  
- Easy to over-engineer and blow your latency budget.

**Mitigations**  
- Restrict to **two-stage or three-stage plans**, not free-form agents.  
- Use coarse **“retrieval planner”** that decides query decomposition and which index to query.

**Recent work & CAQue angle**  
- [Zhang et al., 2025] *“LevelRAG”*– high-level searcher + low-level searchers. :contentReference[oaicite:6]{index=6}  
  - *Goal*: Use query decomposition into atomic sub-queries.  
  - *For CAQue*: Make **“retrieval plan”** an explicit data structure in the pipeline.  
- [Verma et al., 2025] *“PLAN-RAG: Planning-guided Retrieval Augmented Generation”* – matches plan-then-retrieve paradigm. :contentReference[oaicite:7]{index=7}  

For CAQue: Make the pipeline modular enough to plug in a “planner” stage later.

---

## 5. Guardrails Against LLM Bullshit

#### What this class is  
Preventing or detecting hallucinations / unfaithful answers, especially in enterprise settings where “sounds plausible” but wrong can cost real money.

#### Relevance to CAQue  
If you want enterprise adoption, you *must* have a **trust story**:
- Faithfulness checks  
- Citation quality  
- Monitoring hallucination rates over time  

---

#### 5.1 Faithfulness Checks  
**What it is**  
Post-hoc or in-loop checks that the answer is **supported by retrieved context**:  
- NLI-style models (entailment).  
- LLM-as-judge scoring.  
- Metamorphic tests (perturb inputs and see if answer behaves sanely).

**Pros**  
- Catch egregious hallucinations.  
- Can output confidence scores or trigger human review.

**Cons**  
- Extra models & cost.  
- Judgments can be noisy, especially cross-domain.

**Mitigations**  
- Use **binary “safe/unsafe”** thresholds rather than pretend you can get perfect calibration.  
- Start with **LLM-as-judge** using a prompt (“Is this answer faithful to the citations?”).  
- Only run heavy checks for high-risk tenants / queries.

**Recent work & CAQue angle**  
- *FaithJudge & hallucination leaderboards (Vectara 2025)* – benchmarks faithfulness in RAG via LLM-as-judge.  
- *“Correctness is Not Faithfulness in RAG” (Wallat et al. 2025)* – shows that just having a correct citation isn’t enough; citation must actually *cause* the answer.  

For CAQue:  
- Short-term: simple **faithfulness scorer** using LLM-as-judge + context.  
- Long-term: integrate metamorphic tests as part of **eval suite**.

---

#### 5.2 “Show your citations” mode  
**What it is**  
Force the model to output **inline citations** tied to the retrieved chunks (e.g., [1], [2]) and map to doc IDs / URLs.

**Pros**  
- Increases user trust.  
- Enables automated evaluation of citation correctness / faithfulness.  
- Encourages more grounded responses.

**Cons**  
- Models can mis-attribute citations.  
- Formatting gets messy; UX must handle it.

**Mitigations**  
- Post-process citations (like CiteFix) instead of trusting raw LLM output.  
- Evaluate citation correctness and fix or drop wrong ones.

**Recent work & CAQue angle**  
- *CiteFix (2025)* – post-processing to improve citation accuracy with minimal cost.  
- *RAGE & related work* – use citation metrics to evaluate RAG.  

For CAQue:  
- Make citations **mandatory** for “factual QA” modes.  
- Build a generic **citation data model** (chunk_id, char_span, doc_url).  
- Allow tenant UI to style citations however they want.

---

## 6. Domain Adaptation / Structured Retrieval

#### What this class is  
Moving beyond “documents as bags of words” to use **schemas, graphs, domain structure**:
- Tables, APIs, CRM objects, product hierarchies  
- Knowledge graphs  

#### Relevance to CAQue  
This is where you can start morphing from “RAG framework” to “RAG substrate for enterprise systems.” Enterprises *already* have schemas and graphs; you need to plug into them.

---

#### 6.1 Schema-Aware Retrieval  
**What it is**  
Use domain schemas (tables, JSON, code, API descriptions) to:
- Retrieve structured records, not just text.  
- Embed both text and schema metadata.  
- Let LLM reason over structured + unstructured evidence.

**Pros**  
- Better performance on tasks where values live in DBs or APIs.  
- Ensures you’re reading latest data, not doc snapshots.

**Cons**  
- Needs connectors & schema mapping.  
- Some LLMs struggle with complex structured prompts.

**Mitigations**  
- Do **hybrid retrieval**: structured queries (SQL/filters) + text search.  
- Summarise structured outputs into LLM-friendly snippets.

**Recent work & CAQue angle**  
- *“Advancing RAG for Structured and Semi-Structured Data” (Cheerla et al., 2025)* – hybrid retrieval using BM25, dense, metadata-aware filtering for structured data.  

For CAQue:  
- Define a **schema ingestion interface**: given a table or API, CAQue knows how to:  
  - Build metadata-aware filters  
  - Join structured results with text context

---

#### 6.2 Graph-augmented Retrieval  
**What it is**  
Use a **knowledge graph** (or graph derived from text) to:  
- Expand retrieval via neighbours  
- Organise context around entity/relationship paths  
- Guide multi-hop reasoning

**Pros**  
- Better at coverage of related facts.  
- More coherent long answers.  
- Especially good in complex domains (biomed, legal, enterprise orgs).

**Cons**  
- Building/maintaining KGs is hard.  
- Graph operations add latency.  
- Graph must stay in sync with text.

**Mitigations**  
- Generate a **lightweight KG** from documents (entities + doc IDs).  
- Link chunks to graph nodes (chunk linking).  
- Use graph selectively for certain query types (multi-hop, cross-doc).

**Recent work & CAQue angle**  
- *KG²RAG (Zhu et al., 2025)* – semantic retrieval → KG-guided expansion & organisation → paragraphs for RAG.  
- *GGR (Liu et al., 2025)* – GNN-guided KG-RAG.  
- *GraphRAG / Graph-based enterprise posts* – big wins on cross-document reasoning.  

For CAQue:  
- Don’t try to be “GraphRAG” v1, but:  
  - Provide **hooks** for tenants who already have graphs.  
  - Offer basic **doc-derived graph**: entities + doc IDs + links.

---

#### 6.3 Logit Bias for Domain Terms  
**What it is**  
Use logit bias / vocabulary steering so that the LLM:
- Prefers domain-specific terms present in context.  
- Avoids generic replacements (“employee handbook” vs “staff manual”).

**Pros**  
- More consistent terminology.  
- Reduces generic hallucinated phrasing.  
- Useful for brand names, product names, internal acronyms.

**Cons**  
- Logit bias APIs are model-specific.  
- Can cause weird outputs if misconfigured.

**Mitigations**  
- Apply bias only on a **small curated term list** per tenant.  
- Keep bias magnitudes modest; test thoroughly.

**Recent work & CAQue angle**  
This is more practice than formal research; many enterprise RAG whitepapers mention **vocabulary steering**.  

For CAQue:  
- Offer a **“preferred vocabulary” config** at tenant level.  
- Later: auto-suggest vocabulary lists from their corpus.

---

## 7. Conversational Memory / Localised Thread State

#### What this class is  
Multi-turn RAG: keeping track of what’s been said, what’s retrieved before, what the user cares about over time.

#### Relevance to CAQue  
You already think like a distributed-systems engineer. Treat a conversation as a **stateful process**, not stateless Q/A. This is a natural place for CAQue to overperform.

---

#### 7.1 Short-term memory embeddings (conversation-aware retrieval)  
**What it is**  
Embed conversation turns and use them:  
- As additional retrieval signals (“the user and I have been talking about VPN, not HR”)  
- To disambiguate pronouns and references.

**Pros**  
- Better contextual relevance.  
- Reduces repeated clarifications.

**Cons**  
- Memory grows over time; retrieval over it can get expensive.  
- Risk of retrieving outdated context (e.g., superseded answers).

**Mitigations**  
- Keep short-term memory **bounded** (last N turns + summary).  
- Summarise older turns.

**Recent work & CAQue angle**  
- *RAG memory surveys (2025)* – review of memory architectures in conversational LLMs + vector DB + RAG.  
- *Multi-turn RAG benchmarks (MTRAG)-style* – evaluate multi-turn retrieval & reasoning.  

For CAQue:  
- Provide a built-in **conversation memory store** and retrieval hook, separate from the main KB.  
- Let tenants tune: memory length, summarisation strategy.

---

#### 7.2 Long-term memory (summaries, facts, commitments)  
**What it is**  
Persist distilled facts about the user or ongoing task:  
- User prefs, company-specific decisions, “we agreed X last week”  
- Stored as structured objects or summarized notes.

**Pros**  
- Supports long-lived workflows and agents.  
- Reduces re-asking the same questions.

**Cons**  
- Risk of storing wrong information.  
- Can conflict with up-to-date KB content.

**Mitigations**  
- Include **timestamps and confidence** on stored facts.  
- Periodically reconcile with authoritative sources.

**Recent work & CAQue angle**  
Long-term memory is covered in memory architecture surveys.

For CAQue:  
- Offer a **long-term memory interface**:  
  - A simple key-value or fact-graph store  
  - LLM helpers to update it cautiously.

---

#### 7.3 Multi-turn reference disambiguation  
**What it is**  
Resolve pronouns and shorthand:  
- “That policy” → which one?  
- “The second option you mentioned” → map back to specific chunk/doc.

**Pros**  
- Critical for enterprise conversational UX.  
- Reduces misinterpretation.

**Cons**  
- Needs either:  
  - LLM-based resolution over recent turns  
  - or a graph of “mentions” and their bindings

**Mitigations**  
- Use a small **coreference resolver** over recent turns.  
- Use retrieval over conversation memory (“find which entity was just discussed”).

**Recent work & CAQue angle**  
Benchmarks like MTRAG (2025) focus on multi-turn QA where context tracking is essential.

For CAQue:  
- Make **reference resolution** an explicit step in the pipeline:  
  - Raw user query → rewritten, de-referenced query

---

## 8. Evaluation & Feedback Loops

#### What this class is  
You cannot treat this as an afterthought. Real RAG deployment = constant **measurement**:  
- Retrieval quality  
- Generation faithfulness  
- Drift over time  

#### Relevance to CAQue  
A major differentiator for CAQue can be **first-class RAG evaluation tooling**, instead of “you figure it out with LangChain / random dashboards.”

---

#### 8.1 Synthetic Queries for Recall Testing  
**What it is**  
Use LLMs to generate synthetic:  
- queries  
- answers  
- sometimes labels  
from your corpus; then evaluate retrieval + generation performance.

**Pros**  
- Cheap way to build eval sets without full human labeling.  
- Lets you compare chunking/retrieval configs quickly.  
- Enables automated acceptance checks before deploying changes.

**Cons**  
- Synthetic queries may not match real user distribution.  
- LLM-generated answers can be wrong, polluting labels.

**Mitigations**  
- Mix in **small human-validated subset**.  
- Use LLM-as-judge for scoring, not as ground truth.

**Recent work & CAQue angle**  
- *ARES (Saad-Falcon et al., 2024)* – automated RAG evaluation using synthetic queries + LLM judges.  
- *FRAMES (2024)* – unified dataset for factuality, retrieval, reasoning in RAG.  

For CAQue:  
- Build a **“synthetic eval kit”**:  
  - Given a corpus, auto-generate 100-500 synthetic queries + answers  
  - Run them through different CAQue pipelines  
  - Output recall/precision/faithfulness metrics  

---

#### 8.2 “Drift detection” for content updates  
**What it is**  
Monitor changes over time:  
- **Data drift** – new docs, updated policies  
- **Concept drift** – meaning of queries changes  
- **Model drift** – new model versions behave differently  

**Pros**  
- Prevents silent degradation.  
- Gives you a story for enterprises: “We know when it breaks.”  

**Cons**  
- Non-trivial to implement; metrics can be fuzzy.  
- Requires historical logs, not just snapshots.

**Mitigations**  
- Track simple KPIs:  
  - context recall  
  - answer faithfulness  
  - user feedback rates  
- Alert on significant deltas.

**Recent work & CAQue angle**  
- Industry resources on **retrieval drift monitoring** and concept-drift adaptation.  
- RAG evaluation pieces emphasising continuous monitoring in production.  

For CAQue:  
- Incorporate **drift dashboards** at the framework level:  
  - by corpus  
  - by tenant  
  - before/after model version changes  

---

## Recommendations for CAQue

### A. Immediate Priorities (next MVP iterations)  
1. **Lock in Retrieval as a configurable pipeline**  
   - Implement **hybrid retrieval** in OpenSearch: BM25 + dense or neural sparse + dense.  
   - Add a **simple reranker**: start with a small cross encoder.  
   - Add **optional query expansion**: start with HyDE-style “generate hypothetical answer → embed.”

2. **Chunking v1.5 – metadata-aware, with overlap**  
   - Implement **metadata-aware semantic chunking** using headings/sections.  
   - Support configurable **overlap** per index.  
   - Store basic metadata: doc_id, section_title, page, etc.  

3. **Context Builder abstraction**  
   - Extract from your current pipeline a formal **ContextBuilder**:  
     - dedupe hits  
     - group by document  
     - attach metadata/roles  
   - Provide two strategies:  
     - Simple “top-k raw chunks”  
     - “Grouped by document” with basic summarisation  

4. **Citations and Logging**  
   - Add a **mandatory citation mode** for factual QA paths.  
   - Log retrieved chunk IDs, citations used, faithfulness scores (basic LLM-as-judge).  

5. **Basic Evaluation Harness**  
   - Implement a tiny ARES-inspired eval workflow:  
     - synthetic queries from corpus  
     - LLM-as-judge scoring of answer relevance/faithfulness  

---

### B. Changes to the MVP Design  
- **Make pipelines first-class**: retrieval/generation as structured Elixir pipelines.  
- **Design document schema for multi-representation**: allow multiple vector fields, rich metadata.  
- **Split memory from KB**: keep conversation memory in a separate index/store from main corpus.  

---

### C. Most Relevant to Scaling CAQue  
- **Configurable Retrieval Recipes**: Each customer gets a slightly different recipe (hybrid weights, chunking strategy, reranking depth).  
- **Evaluation & Monitoring Built-In**: CAQue ships with synthetic eval, faithfulness scoring, drift dashboards.  
- **Hooks for Structure (Schemas, Graphs)**: Allow ingestion of SQL/NoSQL tables + graphs as retrieval sources.  

---

### D. Potential Competitive Advantages to Seize Early  
1. **Multi-Representation Chunking as First-Class Feature** – Most tools treat chunks as single vector; you offer multiple embeddings per chunk with schema and weighting.  
2. **Built-in Chunking Evaluation Lab** – Let customers test multiple chunking configs and see metrics side-by-side.  
3. **Conversation-Aware Enterprise RAG** – Built-in short & long term memory and multi-turn tracking, not just single Q/A.  
4. **Evaluation as Part of the Core Story** – Not optional; you market CAQue as “we build, measure, monitor your RAG” not just “we build it”.

---

### Reality Check / Obstacles  
- **Risk 1 – Overengineering early**: You have the brain to chase LevelRAG/graphs and Gaussian QE spaces. The danger is building “RAG research lab of your dreams” instead of a sellable v1.  
  - *Mitigation*: Ship **Hybrid + Rerank + Semantic chunking + Citations + Basic eval** first; everything else is **Phase 2**.  
- **Risk 2 – Self-punishment loops via perfectionism**: If you catch yourself thinking “it’s not worth launching unless it’s state-of-the-art across all eight dimensions,” that’s the sabotage talking, not the engineer.  
  - *Mitigation*: Define a **hard MVP threshold** and move.  

---

**If you like**, next step I can turn this into a **CAQue “tech vision” doc** or design the **exact Elixir module boundaries** for the pipeline so you can begin cutting code without thrash.
1. Retrieval (because naive vector search is mid)
What this class is

This is everything about how you select candidate chunks from the corpus before the LLM sees anything. If retrieval sucks, nothing downstream fixes it. Hybrid search, reranking, and query expansion are three levers to boost recall and precision beyond “cosine similarity on a single embedding.”

In real RAG systems, retrieval is often 70–80% of the quality story. 
ACL Anthology
+1

Relevance to CAQue

CAQue is meant to be a framework, not just a toy app. That means your retrieval layer has to be:

Configurable (per-tenant / per-domain retrieval recipes)

Composable (query → retrieve → re-rank → post-filter)

Observable (you can see why a query failed)

Hybrid, reranking, and query expansion should be first-class pipeline stages CAQue exposes.

1.1 Hybrid Search

What it is

Combine sparse (BM25 / neural sparse) and dense (embeddings) retrieval into one ranked list. Either via score fusion (e.g., weighted sum) or multi-stage (BM25 → dense filter or vice versa). Hybrid is now broadly “best default” for RAG. 
ACL Anthology
+2
Amazon Web Services, Inc.
+2

Pros

Much better robustness on:

rare terms, IDs, codes (BM25/neural sparse)

paraphrases and fuzzy language (dense)

Works well on enterprise KBs that mix jargon with natural language.

Plays nicely with OpenSearch (you already get BM25 + dense + neural sparse). 
Amazon Web Services, Inc.

Cons

Score fusion is fiddly (how to weight sparse vs dense).

Latency and infra complexity (multiple retrievers).

Can over-emphasize long docs or spammy fields if BM25 isn’t tuned.

Mitigations

Learn weights per index or per tenant (simple grid search or small regression model).

Normalize scores (z-score or min–max per retriever).

Use metadata filters and field-specific boosts to keep BM25 sane (e.g., title > body).

Recent work & CAQue angle

“Searching for Best Practices in RAG” (Wang et al. 2024) – large empirical study; finds that Hybrid Search + HyDE-style query rewriting is often the best tradeoff of accuracy vs latency across benchmarks. 
ACL Anthology

Goal: Benchmark a ton of RAG configs (retrievers, chunking, reranking).

Practicality: Extremely high; these are literally off-the-shelf setups.

Future: More adaptive hybrids (e.g., dynamic weighting per query).

For CAQue: Treat their recommended “Hybrid + HyDE” recipe as a default retrieval preset.

AWS OpenSearch neural sparse + dense hybrid blog (2024) – shows that combining dense vectors with OpenSearch’s neural sparse search improves RAG retrieval for KBs, often more simply than BM25+dense. 
Amazon Web Services, Inc.

Goal: Demonstrate practical hybrid on real infra (OpenSearch).

Practicality: Maximal—this is exactly your stack.

For CAQue:

Build a standard OpenSearch hybrid retriever module: BM25 or neural sparse + dense with tunable weights and field boosts.

Offer config templates like:

“Docs KB hybrid”

“Code/docs hybrid”

“FAQ-heavy KB hybrid”

Domain-specific hybrid QA (2024/2025 work like “Domain-specific Question Answering with Hybrid Search”) – shows hybrid dense+BM25 significantly boosts QA in specialized domains. 
arXiv

Independent research ideas

Learn per-tenant fusion weights from minimal feedback (clicks / thumbs up/down).

Evaluate whether OpenSearch neural sparse + dense beats classic BM25+dense for the specific enterprise domains you target and publish that as a “CAQue Retrieval Study.”

1.2 Re-ranking Pipelines

What it is

Two-stage retrieval: first get a big candidate pool (e.g. top-50 or top-100 chunks), then score each candidate more precisely with a cross encoder or LLM-as-reranker, producing a much better top-5. 
Pinecone
+1

Pros

Huge quality bump, especially in noisy KBs (duplicate docs, irrelevant boilerplate).

You can keep recall high while controlling LLM context size.

Great in high-stakes domains (compliance, finance, medical).

Cons

Extra latency (heavy model scoring 50–100 candidates).

Additional infra complexity (GPU/CPU serving, batching, caching).

If your baseline retrieval is garbage, reranking can’t fix it.

Mitigations

Use efficient cross encoders (e.g., MiniLM, MPNet) and batch across tenants.

Cache reranker scores for repeated queries or canonical question templates.

Use adaptive candidate set sizes (k=30 for short queries, k=100 for multi-hop).

Recent work & CAQue angle

KG²RAG (Zhu et al., 2025) – combines semantic retrieval with KG-guided organization and reranking; uses cross-encoders to measure paragraph-level relevance guided by a knowledge graph structure. 
ACL Anthology
+1

Goal: Improve coherence and relevance by using KG structure plus reranking.

Practicality: Moderate–high for enterprises that have graphs or can derive them (CRM, product catalogs).

Future: Graph-aware rerankers that treat “document + neighbors” as one unit.

For CAQue: Aligns strongly with a “structured retrieval preset”: graph + dense + rerank.

Biomedical RAG with cross-encoder + GPT reranking (2025) – “Beyond Retrieval: Ensembling Cross-Encoders and GPT” 
arXiv

Goal: Use ensembles of cross-encoders and LLM rerankers for PubMed QA.

Practicality: High in domains with standard corpora; cost goes up.

For CAQue: Inspiration for pluggable reranker backends (“cheap cross-encoder,” “LLM reranker,” “ensemble”) configurable per tenant.

Tons of industry writeups (Pinecone, Databricks, blogs) show reranking as one of the simplest big wins for RAG. 
Pinecone
+2
Nb Data
+2

Independent research ideas

Re-rank not chunks but chunk-groups (e.g. all chunks from the same doc or section).

Use multi-objective reranking for enterprise: relevance + recency + access control.

1.3 Query Expansion

What it is

Automatically expand or rewrite a user query into richer representations: paraphrases, related terms, or synthetic “ideal answers” whose content you then retrieve against.

Includes HyDE-style “generate a hypothetical answer, embed that” and LLM-based query expansion variants. 
ACL Anthology
+1

Pros

Fixes short or vague queries (“VPN broken”, “hr policy maternity”).

Bridges lexical gaps (synonyms, abbreviations, multilingual).

Especially strong when combined with hybrid retrieval.

Cons

Can introduce drift if expansions hallucinate irrelevant concepts.

High compute if you generate many expansions per query.

Can hurt precision by pulling in tangential docs.

Mitigations

Limit to 2–3 expansions and keep them short.

Use retrieval feedback: discard expansions whose retrieved set has low similarity to others.

Add a “no expansion” path and AB compare.

Recent work & CAQue angle

LevelRAG (Zhang et al., 2025) – integrates a high-level searcher with multiple low-level searchers (sparse, web, dense) and decouples query rewriting from any single retriever. 
arXiv
+1

Goal: Make query rewriting a general planning layer, not hard-tied to dense retrievers.

Practicality: High at the “framework” level; more complex to implement, but exactly your vibe.

For CAQue: You can steal this idea as your “retrieval planner” abstraction: one module does query decomposition/expansion, and then routes sub-queries across hybrid retrievers.

LLM-QE (Pan et al., 2025) – LLM-based query expansion with a Gaussian-kernel semantic space that refines multiple expansion vectors and improves dense retrieval. 
MDPI
+1

Goal: Make expansions not just longer, but better-positioned in embedding space.

Practicality: Medium; needs infrastructure for multiple embeddings + kernel weighting.

For CAQue: Future research direction, not MVP – but you could implement a simplified “multi-embedding expansion” mode later.

“Exploring Best Practices of Query Expansion with LLMs for IR” (Zhang et al., 2024) – systematic study of LLM-based query expansion (Query2Doc variants). 
ACL Anthology
+1

Takeaway: QE helps weaker retrievers more; strong dense models already do some semantic expansion.

For CAQue: You can make QE optional and mostly useful when tenants use cheaper embeddings.

Independent research

Evaluate per-tenant whether QE helps (you can do small offline tests).

Try RAG-based QE (as in Olivera 2025) where expansions are themselves retrieved and scored. 
SciTePress
+1

2. Chunking
What this class is

Chunking is how you cut raw docs into embedding units. You know this already, but the literature is loud now: chunking strategy can easily swing recall by ~5–10 percentage points across real RAG tasks. 
Chroma Research
+2
Firecrawl - The Web Data API for AI
+2

Relevance to CAQue

CAQue as a framework should treat chunkers as pluggable strategies with:

Defaults (recursive char, semantic, metadata-aware)

Domain-specific presets (PDF reports vs tickets vs code)

Evaluation harnesses (so tenants can see how chunking changes retrieval)

2.1 Semantic Chunking

What it is

Use document structure and semantics (headings, paragraphs, list boundaries, LLM segmenters) instead of dumb “every 512 chars.” 
Databricks Community
+2
Medium
+2

Pros

Higher chance that a chunk is self-contained enough to answer a question.

Fewer “cut in the middle of a concept” issues.

Better for long enterprise docs (policies, SOPs, contracts).

Cons

More complex ingestion (you need robust parsing).

PDF/HTML soup can break structural cues.

Latency / cost if you use an LLM for segmentation (multimodal chunkers). 
arXiv

Mitigations

Use cheap deterministic rules first (headings, sections) and only fall back to LLM chunking for ugly docs.

Cache multimodal chunk results aggressively.

Log “chunk usefulness” over time and refine heuristics.

Recent work & CAQue angle

Chroma “Evaluating Chunking Strategies for Retrieval” (2024) – rigorous analysis of chunking strategies using Recall, Precision, IoU-style metrics; shows that semantic & metadata-aware chunkers beat naive ones. 
Chroma Research
+2
GitHub
+2

Practicality: Very high; they open-sourced tooling.

For CAQue:

Bake in a chunking-eval lab similar to Chroma’s.

Expose that as a CAQue feature – this is something almost no “framework” productizes well.

“Evaluating Advanced Chunking Strategies for RAG” (Merola et al., 2025) – compares late chunking vs contextual retrieval. Contextual retrieval (fetch bigger context then slice) keeps coherence but costs more; late chunking is efficient but loses detail. 
arXiv
+1

For CAQue: Suggests a “contextual retrieval mode” as an advanced option for certain high-value tenants.

Multimodal chunking for PDFs (2025 paper on multimodal RAG chunking) – uses LMMs to handle tables, figures, cross-page structures. 
arXiv

Future: Important for enterprises with heavy reporting / PowerPoints.

2.2 Overlapping Windows

What it is

Allow chunks to overlap so that boundary regions appear in multiple chunks (e.g., 1k tokens with 200-token overlap).

Pros

Reduces “I cut out the crucial sentence” errors.

Essential for code, protocols, stepwise procedures.

Makes retrieval more tolerant to segmentation choices.

Cons

Increases index size and ingest cost.

Can amplify duplicates, leading to retrieval redundancy.

More noise if reranker / generator isn’t smart.

Mitigations

Tune overlap based on doc type (large for code, small for FAQs).

Combine with deduplication in retrieval (merge overlapping hits).

Use chunk grouping at context-assembly time.

Recent work & CAQue angle

Most of the recent chunking studies (Chroma, Snowflake, Firecrawl, etc.) treat overlap as a tunable hyperparameter and show that moderate overlap (10–30%) is generally beneficial, but excessive overlap gives diminishing returns. 
jxnl.co
+3
Chroma Research
+3
Firecrawl - The Web Data API for AI
+3

For CAQue:

Allow per-index overlap configuration.

Provide “profiles” like:

“Long-form policy docs” – moderate overlap.

“Code/API docs” – higher overlap.

2.3 Multi-Representation Chunks

What it is

Store multiple embeddings per chunk, each capturing a different aspect: raw text, summary, entities, maybe separate embeddings for title vs body. Sometimes called multi-vector embeddings. 
baobabtech.ai
+2
newsletter.theaiedge.io
+2

Pros

Better retrieval for:

Entity-heavy queries (use NER embedding).

Conceptual queries (use summary embedding).

Allows you to weight different views at query time.

Cons

More storage.

More complex retrieval logic.

Index maintenance is harder (you now have multiple fields per chunk).

Mitigations

Start with just two representations: full chunk and summary/entities.

Use OpenSearch’s support for multiple vector fields per document.

Use simple fusion rules per query type.

Recent work & CAQue angle

Industry writeups (Baobab, AI Edge, vector DB blogs) show multi-vector yielding significant improvements for heterogenous data. 
baobabtech.ai
+2
newsletter.theaiedge.io
+2

RAG evolution reviews note that token-level or multi-vector representations are increasingly common for complex doc structures. 
ragflow.io
+1

For CAQue:

This is a killer differentiator if you do it cleanly:

Offer a “multi-representation schema” as part of the ingestion config.

Let advanced users plug in their own summarizers/NERs to define extra views.

Independent research:

Study which combinations of representations give best returns for enterprise KBs (e.g. title + summary vs summary + entities).

Build a small paper: “Multi-Representation Chunking for Enterprise RAG with OpenSearch” and publish results.

3. Context Assembly
What this class is

You’ve got a set of retrieved chunks. Now you decide what to send to the LLM and how. Context assembly is about:

Removing duplicates

Grouping related chunks

Annotating their roles

This is hugely impactful for hallucinations and coherence, especially on long contexts. 
OpenAI Developer Community
+1

Relevance to CAQue

Most frameworks treat this as an afterthought. You can make it a first-class pipeline stage:

A “context builder” that’s pluggable per tenant.

Built-in strategies: simple top-k, grouped by document, grouped by section/role, etc.

3.1 Deduplication and Consolidation

What it is

Deduplication: removing near-identical chunks (same text, or high cosine sim).

Consolidation: merging multiple related chunks into concise summaries before sending to the LLM.

Pros

Less wasted context budget.

Reduces conflicting statements.

Makes answers more grounded and concise.

Cons

Summarization can itself hallucinate or drop critical detail.

Extra latency for consolidation step.

Requires careful citation tracking.

Mitigations

Use extractive summaries when possible (pull key sentences instead of abstractive rewrites).

Limit consolidation to chunks from the same doc/section.

Keep links back to all source chunk IDs for citations.

Recent work & CAQue angle

Most RAG best-practice guides emphasize that naive “dump the top N chunks as-is” is suboptimal; some use post-retrieval clustering + summarization. 
Pat McGuinness
+2
morphik.ai
+2

You’re well-positioned to:

Implement a document-level context builder: retrieve chunks → cluster by doc → summarize per doc.

Add a “strict mode” where only exact, non-consolidated chunks are used for high-risk queries.

3.2 Section-aware Assembly

What it is

Group chunks by document sections (e.g., “Section 3: Billing Disputes”) or conceptual “sections” (background, constraints, examples), and feed this structure to the LLM.

Pros

Reduces context confusion by giving the model labeled buckets.

Works well for multi-doc answers (“Policy A says X, Policy B says Y”).

Helps multi-hop reasoning—model sees which chunk is doing what.

Cons

Requires good metadata at ingest (parse headings, hierarchy).

Not all corpora have clean structure (ticket logs, chat).

Prompts get more complex.

Mitigations

For unstructured data, use simple heuristics (source, date, doc type) as pseudo-sections.

Build default prompt scaffolds (“You are given multiple sections: …”).

Recent work & CAQue angle

OpenAI’s “document sections” pattern and similar community resources explicitly show that sectioned context improves RAG QA quality. 
OpenAI Developer Community
+1

For CAQue:

Include a section-aware context template as a core feature.

Expose structured prompts where you pass context as {definitions:[], procedures:[], examples:[]}.

3.3 Context Windows with Roles

What it is

Assign roles to chunks: facts, definitions, constraints, examples, user history, etc., and instruct the LLM how to use them (e.g., “prioritize constraints over examples when conflicts occur”).

Pros

Makes answers more deterministic and policy-compliant.

Lets you handle conflicts (policy vs example) more predictably.

Good fit for enterprise compliance / SOP flows.

Cons

Requires classification of chunks (manual or model-based).

More complicated prompts and context-building.

Mitigations

Start with simple roles based on metadata or heuristics (title, path).

Add optional LLM-based role classification as an offline pipeline.

Recent work & CAQue angle

This is less a specific paper and more a pattern emerging in enterprise RAG whitepapers and technical deep dives, which emphasize role-annotated context for auditability and consistency. 
Shaping the future together
+2
smarttechlabs.de
+2

For CAQue:

Make “role tagging” an optional ingest pipeline stage.

At minimum, always distinguish between:

source docs

retrieval logs

conversation memory

4. Augmented Generation, not Raw Generation
What this class is

Instead of “throw context at LLM and say ‘answer this’”, you structure the reasoning process:

Retrieve → reason over evidence → then answer.

Sometimes with explicit intermediate steps (plans, chains, scratchpads).

This reduces hallucinations and makes explanations more grounded.

Relevance to CAQue

You want CAQue to be more than “LangChain in Elixir.” Generation pipeline templates are a key differentiator:

“Strict QA”

“Summarize across docs”

“Decision memo”

All of them should be procedural templates for reasoning, not just prompts.

4.1 Contextual Reasoning Chains

What it is

LLM explicitly generates intermediate reasoning steps over the retrieved evidence:

Extract key facts from each chunk.

Combine and reconcile facts.

Produce final answer, citing sources.

Pros

Better faithfulness; easier to debug.

Can be reused across queries as a pattern.

Plays nicely with evaluation tools (you can evaluate intermediate steps).

Cons

More tokens and latency.

If not carefully constrained, chain-of-thought can itself hallucinate.

Mitigations

Keep reasoning steps short and almost extractive (“List relevant facts from the context”).

Hide chain-of-thought from end user while still logging it for internal eval.

Put explicit instructions: “Only use facts from the context, quote them when possible.”

Recent work & CAQue angle

Many recent RAG evaluations (FRAMES, ARES, etc.) implicitly assume multi-step reasoning patterns. 
arXiv
+1

For CAQue:

Offer stock reasoning templates:

“Evidence extraction”

“Compare-and-contrast two policies”

CAQue can log intermediate reasoning for analytics (where did it go off the rails?).

4.2 Retrieval-augmented Planning

What it is

LLM first plans the steps required to answer (including what to retrieve), then executes those steps, often with multiple retrieval iterations.

Pros

Crucial for multi-hop, complex workflows (e.g., “find all policies impacted by regulation X and summarize changes since 2022”).

Lets you use different retrievers for different sub-queries.

Cons

More complicated architecture (agents, tools).

Easy to over-engineer and blow your latency budget.

Mitigations

Restrict to two-stage or three-stage plans, not freeform agents.

Use coarse “retrieval planner” that decides query decomposition and which index to query.

Recent work & CAQue angle

LevelRAG again is relevant here: high-level searcher integrates multiple low-level ones. 
arXiv
+1

Recent work on question decomposition + cross-encoder reranking also supports this multi-stage planned retrieval. 
Hugging Face

For CAQue:

Make “retrieval plan” an explicit data structure in the pipeline, not just hidden prompt text.

Later: let advanced users program simple planners (in Elixir) that decide how to query based on question type.

5. Guardrails Against LLM Bullshit
What this class is

Preventing or detecting hallucinations / unfaithful answers, especially in enterprise settings where “sounds plausible” but wrong can cost real money.

Relevance to CAQue

If you want enterprise adoption, you must have a story around trust:

Faithfulness checks

Citation quality

Monitoring hallucination rates over time

5.1 Faithfulness Checks

What it is

Post-hoc or in-loop checks that the answer is supported by retrieved context:

NLI-style models (entailment).

LLM-as-a-judge scoring.

Metamorphic tests (perturb inputs and see if answer behaves sanely).

Pros

Catch egregious hallucinations.

Can output confidence scores or require human review.

Cons

Extra models & cost.

Noisy judgments, especially cross-domain.

Mitigations

Use binary “safe/unsafe” thresholds instead of pretending you can get perfect calibration.

Start with LLM-as-judge using simple faithful/unfaithful prompts.

Only run heavy checks for high-risk tenants / queries.

Recent work & CAQue angle

FaithJudge & hallucination leaderboards (Vectara 2025) – benchmarks faithfulness in RAG via LLM-as-judge. 
ACL Anthology
+2
arXiv
+2

“Correctness is Not Faithfulness in RAG” (Wallat et al. 2025) – shows that just having a correct citation is not enough; citation must actually cause the answer. 
arXiv
+2
ACM Digital Library
+2

MetaRAG (2025) – metamorphic testing framework for hallucinations in real-world RAG where gold labels are missing. 
arXiv

For CAQue:

Short-term: simple faithfulness scorer using LLM-as-judge and context.

Long-term: integrate metamorphic tests as part of eval suite for tenants.

5.2 “Show your citations” mode

What it is

Force the model to output inline citations tied to the retrieved chunks (e.g., [1], [2]) and then map to doc IDs / URLs.

Pros

Increases user trust.

Enables automated evaluation of citation correctness / faithfulness.

Encourages more grounded responses.

Cons

Models can mis-attribute citations.

Formatting gets messy; UX must be handled by the app.

Mitigations

Post-process citations (like CiteFix) instead of trusting raw LLM output. 
arXiv

Evaluate citation correctness and fix or drop wrong ones.

Recent work & CAQue angle

CiteFix (2025) – post-processing to improve citation accuracy with minimal cost. 
arXiv

RAGE & related work – use citation metrics to evaluate and fine-tune RAG. 
ACL Anthology
+2
arXiv
+2

For CAQue:

Make citations mandatory for “factual QA” modes.

Build a generic citation data model (chunk_id, char_span, doc_url).

Allow tenant UI to style citations however they want.

6. Domain Adaptation / Structured Retrieval
What this class is

Moving beyond “documents as bags of words” to use schemas, graphs, and domain structure:

Tables, APIs, CRM objects, product hierarchies.

Knowledge graphs.

Relevance to CAQue

This is where you can start morphing from “RAG framework” to “RAG substrate for enterprise systems.” Enterprises already have schemas and graphs; you need to plug into them.

6.1 Schema-Aware Retrieval

What it is

Use domain schemas (tables, JSON, code, API descriptions) to:

Retrieve structured records, not just text.

Embed both text and schema metadata.

Let LLM reason over structured + unstructured evidence.

Pros

Better performance on tasks where values live in DBs or APIs.

Ensures you’re reading latest data, not doc snapshots.

Cons

Needs connectors & schema mapping.

Some LLMs struggle with complex structured prompts.

Mitigations

Do hybrid retrieval: structured queries (SQL/filters) + text search.

Summarize structured outputs into LLM-friendly snippets.

Recent work & CAQue angle

“Advancing RAG for Structured and Semi-Structured Data” (Cheerla et al., 2025) – hybrid retrieval using BM25, dense, and metadata-aware filtering for structured data. 
arXiv

For CAQue:

Define a schema ingestion interface: given a table or API, CAQue knows how to:

Build metadata-aware filters.

Join structured results with text context.

6.2 Graph-augmented Retrieval

What it is

Use a knowledge graph (or graph derived from text) to:

Expand retrieval via neighbors.

Organize context around entity/relationship paths.

Guide multi-hop reasoning.

Pros

Better at coverage of related facts.

More coherent long answers.

Especially good in complex domains (biomed, legal, enterprise orgs).

Cons

Building/maintaining KGs is hard.

Graph operations add latency.

Graph must stay in sync with text.

Mitigations

Generate a lightweight KG from documents (entities + doc IDs).

Link chunks to graph nodes (chunk linking). 
Medium
+1

Use graph selectively for certain query types (multi-hop, cross-doc).

Recent work & CAQue angle

KG²RAG (Zhu et al., 2025) – semantic retrieval → KG-guided expansion & organization → paragraphs for RAG. 
ACL Anthology
+2
ACL Anthology
+2

GGR (Liu et al., 2025) – GNN-guided KG-RAG; uses GNNs to preserve key reasoning paths in graphs. 
OpenReview

GraphRAG / Graph-based enterprise posts – show big wins on cross-document reasoning. 
ResearchGate
+1

For CAQue:

Don’t try to be “GraphRAG” v1, but:

Provide hooks for tenants who already have graphs.

Offer basic doc-derived graph: entities + doc IDs + links.

6.3 Logit Bias for Domain Terms

What it is

Use logit bias / vocabulary steering so that the LLM:

Prefers domain-specific terms present in context.

Avoids generic replacements (“employee handbook” vs “staff manual”).

Pros

More consistent terminology.

Reduces generic hallucinated phrasing.

Useful for brand names, product names, internal acronyms.

Cons

Logit bias APIs are model-specific.

Can cause weird outputs if misconfigured.

Mitigations

Apply bias only on a small curated term list per tenant.

Keep bias magnitudes modest; test thoroughly.

Recent work & CAQue angle

This is more practice than formal research; many enterprise RAG whitepapers mention vocabulary steering as a technique for brand-safe output. 
Shaping the future together
+1

For CAQue:

Offer a “preferred vocabulary” config at tenant level.

Later: auto-suggest vocabulary lists from their corpus.

7. Conversational Memory / Localized Thread State
What this class is

Multi-turn RAG: keeping track of what’s been said, what’s retrieved before, and what the user cares about over time.

Relevance to CAQue

You already think like a distributed systems guy. Treat a conversation as a stateful process, not a stateless Q/A. This is a natural place for CAQue to overperform.

7.1 Short-term memory embeddings (conversation-aware retrieval)

What it is

Embed conversation turns and use them:

As additional retrieval signals (“the user and I have been talking about VPN, not HR”).

To disambiguate pronouns and references.

Pros

Better contextual relevance.

Reduces repeated clarifications.

Cons

Memory grows over time; retrieval over it can get expensive.

Risk of retrieving outdated context (e.g., superseded answers).

Mitigations

Keep short-term memory bounded (last N turns plus summary).

Summarize older turns.

Recent work & CAQue angle

RAG memory surveys (2025) – review of RAG-driven memory architectures in conversational LLMs, emphasizing vector DB + RAG for context. 
Vlaams Instituut voor de Zee
+1

Multi-turn RAG benchmarks like MTRAG/mtRAG (2025) – explicitly evaluate multi-turn retrieval and reasoning. 
arXiv
+2
ResearchGate
+2

For CAQue:

Provide a built-in conversation memory store and retrieval hook, separate from the main KB.

Let tenants tune:

memory length

summarization strategy

7.2 Long-term memory (summaries, facts, commitments)

What it is

Persist distilled facts about the user or ongoing task:

User prefs, company-specific decisions, “we agreed X last week”.

Stored as structured objects or summarized notes.

Pros

Supports long-lived workflows and agents.

Reduces re-asking the same questions.

Cons

Risk of storing wrong information.

Can conflict with up-to-date KB content.

Mitigations

Include timestamps and confidence on stored facts.

Periodically reconcile with authoritative sources.

Recent work & CAQue angle

Long-term memory is covered in conversational memory surveys and in RAG evaluation for multi-turn tasks. 
Vlaams Instituut voor de Zee
+1

For CAQue:

Offer a long-term memory interface:

A simple key-value or fact-graph store.

LLM helpers to update it cautiously.

7.3 Multi-turn reference disambiguation

What it is

Resolve pronouns and shorthand:

“That policy” → which one?

“The second option you mentioned” → map back to specific chunk/doc.

Pros

Critical for enterprise conversational UX.

Reduces misinterpretation.

Cons

Needs either:

LLM-based resolution over prior turns

or a graph of “mentions” and their bindings.

Mitigations

Use a small coreference resolver over recent turns.

Use retrieval over conversation memory (“find which entity was just discussed”).

Recent work & CAQue angle

Benchmarks like MTRAG focus on multi-turn QA where context tracking is essential. 
arXiv
+1

For CAQue:

Make reference resolution an explicit step in the pipeline:

Raw user query → rewritten, de-referenced query.

8. Evaluation & Feedback Loops
What this class is

You cannot treat this as an afterthought. Real RAG deployment = constant measurement:

Retrieval quality

Generation faithfulness

Drift over time

Relevance to CAQue

A major differentiator for CAQue can be first-class RAG evaluation tooling, instead of “you figure it out with LangSmith / random dashboards.”

8.1 Synthetic Queries for Recall Testing

What it is

Use LLMs to generate synthetic:

queries

answers

sometimes labels

from your corpus; then evaluate retrieval and generation on these. 
Modulai
+3
ACL Anthology
+3
ACM Digital Library
+3

Pros

Cheap way to build eval sets without human labeling.

Lets you compare chunking/retrieval configs quickly.

Enables automated acceptance checks before deploying changes.

Cons

Synthetic queries may not match real user distribution.

LLM-generated answers can be wrong, polluting labels.

Mitigations

Mix in small human-validated subset.

Use LLM-as-judge for scoring, not as ground truth.

Recent work & CAQue angle

ARES (Saad-Falcon et al., 2024) – automated RAG evaluation using synthetic queries and LLM judges. 
ACL Anthology

FRAMES (2024) – unified dataset to evaluate factuality, retrieval, and reasoning in RAG. 
arXiv

Synthetic test collections for IR (2024) – fully synthetic IR benchmarks with LLMs. 
ACM Digital Library

For CAQue:

Build a “synthetic eval kit”:

Given a corpus, auto-generate 100–500 synthetic queries + answers.

Run them through different CAQue pipelines.

Output recall/precision/faithfulness metrics.

8.2 “Drift detection” for content updates

What it is

Monitor changes over time:

Data drift – new docs, updated policies.

Concept drift – meaning of queries changes.

Model drift – new model versions behave differently.

Pros

Prevents silent degradation.

Gives you a story for enterprises: “we know when it breaks.”

Cons

Nontrivial to implement; metrics can be fuzzy.

Requires historical logs, not just snapshots.

Mitigations

Track simple KPIs:

context recall

answer faithfulness

user feedback rates.

Alert on significant deltas.

Recent work & CAQue angle

Industry resources on retrieval drift monitoring and concept drift adaptation. 
ApX Machine Learning
+2
Rohan's Bytes
+2

RAG evaluation pieces emphasize the need for continuous monitoring in production. 
morphik.ai
+2
Braintrust
+2

For CAQue:

Incorporate drift dashboards at the framework level:

By corpus

By tenant

Before/after model version changes

Recommendations for CAQue

Here’s the pragmatic bit: what to do now, what to tweak in the MVP, and where you can actually get edge.

A. Immediate Priorities (next MVP iterations)

Lock in Retrieval as a configurable pipeline

Implement hybrid retrieval in OpenSearch:

BM25 + dense or neural sparse + dense, with tunable weights. 
Amazon Web Services, Inc.
+1

Add a simple reranker:

Start with a small cross-encoder on CPU or cheap GPU.

Add optional query expansion:

Start with HyDE-style “generate hypothetical answer → embed.” 
ACL Anthology
+1

Chunking v1.5 – Metadata-aware, with overlap

Implement metadata-aware semantic chunking using headings / sections where available. 
Chroma Research
+2
Databricks Community
+2

Support configurable overlap per index.

Store basic metadata: doc_id, section_title, page, etc.

Context Builder abstraction

Extract from your current pipeline a formal ContextBuilder:

Dedup hits.

Group by document.

Attach metadata/roles.

Provide two strategies:

Simple “top-k raw chunks”

“Grouped by document” with basic summarization.

Citations and Logging

Add a mandatory citation mode for factual QA paths.

Log:

retrieved chunk IDs

citations used

faithfulness scores (basic LLM-as-judge)

Basic Evaluation Harness

Implement a tiny ARES-inspired eval workflow:

Synthetic queries from corpus.

LLM-as-judge scoring of answer relevance / faithfulness. 
ACL Anthology
+2
Modulai
+2

This is enough to make CAQue feel like a serious framework, not “DIY LangChain.”

B. Changes to the MVP Design

None of this requires a total rewrite, but a few structural decisions matter now:

Make pipelines first-class

Represent retrieval/generation as a structured Elixir pipeline:

query_normalize -> planner (optional) -> retriever(s) -> reranker -> context_builder -> generator -> guardrails

Store configs in a domain-agnostic YAML/JSON so tenants can define pipelines declaratively.

Design the document schema for multi-representation

Even if you don’t fully exploit it yet, define your OpenSearch schema to allow:

multiple vector fields (raw, summary, entities)

rich metadata

This avoids migration pain later. 
baobabtech.ai
+1

Split memory from KB

Keep conversational memory in a separate index / store from the main corpus.

Define a clean API between:

conversation-memory retrieval

corpus retrieval

C. Most Relevant to Scaling CAQue

When you start doing high-touch implementations like Databricks/Palantir, what will matter most:

Configurable Retrieval Recipes

Each customer gets a slightly different:

hybrid weights

chunking strategy

reranking depth

You want CAQue to let you tweak this in config, not code.

Evaluation & Monitoring Built In

CAQue ships with:

synthetic eval harness

faithfulness scoring

drift dashboard hooks

This lets you say to enterprises: “We don’t just build your RAG, we monitor and tune it over time.” 
Medium
+1

Hooks for Structure (Schemas, Graphs)

You don’t need full KG²RAG day one, but:

Have the extension points for graph-based retrieval.

Allow ingestion from SQL/NoSQL tables with domain-aware filters.

D. Potential Competitive Advantages You Could Seize Early

These are the “this actually looks novel” angles that align with how your brain works.

Multi-Representation Chunking as a First-Class Feature

Most tools still treat chunks as a single embedding.

CAQue can:

Define a multi-vector document schema

Provide stock pipelines for combining them

This plays to your strength (schema design + OpenSearch familiarity). 
baobabtech.ai
+1

Built-in Chunking Evaluation Lab

Almost no one productizes Chroma-style chunking eval as a first-class feature. 
Chroma Research
+1

CAQue could let a customer:

Upload corpus

Try 3–4 chunking configs

See side-by-side metrics and example queries

Conversation-Aware Enterprise RAG

Many products still treat each query as stateless.

You can bake in:

short-term memory embeddings

basic long-term memory

multi-turn evaluation (MTRAG-style) 
arXiv
+2
IBM Research
+2

That’s a nice wedge: “CAQue is for ongoing knowledge work, not just single questions.”

Evaluation as Part of the Core Story

Use ARES/FRAMES ideas to make evaluation part of the standard CAQue deployment. 
ACL Anthology
+2
arXiv
+2

You pitch: “We help you measure and not just build RAG.”

Reality Check / Obstacles

Just to keep it honest:

Risk 1 – Overengineering early
You absolutely have the brain to chase LevelRAG/GG2RAG graphs and Gaussian QE spaces. The danger is trying to build the “RAG research lab of your dreams” instead of a sellable v1.

Mitigation:

Ship Hybrid + Rerank + Semantic chunking + Citations + Basic eval first.

Treat everything else as “Phase 2 modules.”

Risk 2 – Self-punishment loops via perfectionism
If you catch yourself thinking “it’s not worth launching unless it’s state-of-the-art across all eight dimensions,” that’s the sabotage talking, not the engineer. A lot of very mid RAG SaaS is making money right now.

Mitigation:

Define a hard MVP threshold:

Hybrid retrieval

Semantic chunking

Citations

Basic synthetic eval

Anything beyond that is explicitly backlog, not “secret requirement.”
