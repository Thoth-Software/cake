# Caque 

## 🗺 Sprint 1: Foundational Setup (Week 1)
### 🟩 Goal:
Establish foundational infrastructure, automated ingestion pipeline, embedding generation, and OpenSearch indexing.

### 📌 Tasks:

- **Docker Environment (12 hrs)**  
  - Docker Compose setup (Phoenix, PostgreSQL 14, OpenSearch)
  - Configure Phoenix connections (DB, OpenSearch)
  - Validate service connectivity

- **Automated Document Ingestion (8 hrs)**  
  - Script to download and parse HexDocs into JSON

- **Embedding Generation via OpenAI (6 hrs)**  
  - Integrate and validate OpenAI embeddings (`text-embedding-ada-002`)

- **Index Embeddings into OpenSearch (6 hrs)**  
  - Elasticsearch Dense Vector indexing schema & scripts

- **Pipeline Integration & Validation (6 hrs)**  
  - End-to-end pipeline testing (≥98% accuracy)

- **CI/CD Setup & Basic Testing (6 hrs)**  
  - Basic GitHub Actions pipeline for Docker builds & integration tests

### 🎯 Sprint 1 Deliverables:
- Dockerized environment fully operational
- Automated ingestion pipeline for HexDocs
- Embeddings generated and indexed successfully
- Basic CI/CD integration tests in place

### ✅ Success Metrics:
| Metric             | Target                                 |
|--------------------|----------------------------------------|
| Docker Setup       | Containers running & interconnected    |
| Ingestion accuracy | ≥98% successful doc ingestion          |
| Embedding Indexing | Embeddings indexed & retrievable       |
| CI/CD              | Basic integration tests passing        |

