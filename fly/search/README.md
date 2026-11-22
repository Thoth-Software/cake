# Runbook: `cake-staging-search`, the shared staging OpenSearch node

The search node every tester app shares (#364, part of the staging epic #360). It is OpenSearch 3.2.0, one node on one Fly machine with one volume, run by us, with no public address, no replica and no backups. Each tester app keeps to its own index namespace (#362). `fly.toml` beside this file is the configuration; `Dockerfile` and `entrypoint.sh` add the one thing it cannot say (the volume's ownership).

**Status: not deployed.** Nothing in this file has been run against Fly yet. "Verified locally" means a local Docker container; "not yet verified" means read in Fly's documentation and not tried. The (verify) boxes on #364 are checked only from the live app.

## Topology

| | |
|---|---|
| Image | `opensearchproject/opensearch:3.2.0` behind a root entrypoint. The tag is the one `quality.yml` and `docker-compose.ci.yml` pin; bump the three together. |
| Machine | shared-cpu-2x, 4 GB, always on (no service section, so Fly's proxy never stops it) |
| Heap | 2 GB (`OPENSEARCH_JAVA_OPTS`). The image fixes the heap at 1 GB whatever the machine has, so this moves with `[[vm]] memory`: half of it. |
| Data | 10 GB volume `search_data` on `/usr/share/opensearch/data`, scheduled snapshots off |
| Address | `http://cake-staging-search.internal:9200`, private network only, plain HTTP, no credentials (security plugin disabled) |
| Health | `[checks.cluster_health]`: `GET /_cluster/health` every 15 s |

Yellow is this node's healthy state: any index with a replica configured can never place it on a single node.

## First deploy

Roughly $26.90 a month in `iad` (machine about $25.40, 10 GB volume $1.50; Fly's pricing page, 2026-11-22).

```sh
fly apps create cake-staging-search --org <org>
cd fly/search
fly deploy --no-public-ips --ha=false
fly ips list -a cake-staging-search      # expect no rows
fly logs -a cake-staging-search          # expect two "cake-search:" lines, then the node's start-up
```

`primary_region` is `iad` as a placeholder. Set it to the region the tester apps and `cake-staging-db` use before the first deploy: a volume cannot move regions.

## Restart

```sh
fly machine list -a cake-staging-search
fly machine restart <machine id> -a cake-staging-search
fly checks list -a cake-staging-search   # passing again within about a minute
```

Data is on the volume and survives a restart, a redeploy and a destroyed machine. While the node is down every tester app is without search.

## Logs and state

```sh
fly logs -a cake-staging-search
fly checks list -a cake-staging-search
fly ssh console -a cake-staging-search -C "curl -s localhost:9200/_cluster/health?pretty"
fly ssh console -a cake-staging-search -C "curl -s localhost:9200/_cat/indices?v"
fly ssh console -a cake-staging-search -C "curl -s localhost:9200/_plugins/_knn/stats/graph_memory_usage,graph_memory_usage_percentage,circuit_breaker_triggered?pretty"
```

From your own machine: `fly proxy 9200:9200 -a cake-staging-search`, then `curl localhost:9200`.

Do not trust "started" alone. A node that fails during start-up (a bad `network.host`, an unwritable data directory) logs the exception and its process stays alive, so the machine shows as started with nothing listening. The health check is the signal.

## What a tester sees when it is down

From reading the LiveViews, not from trying it on staging:

- **Search page:** "Search failed. Please try again."
- **Chat:** the turn ends in an error notice instead of an answer; nothing is retrieved.
- **Upload:** the PDF is stored and parsed, but indexing fails, so the result reports failed sections ("N failed") or "Ingestion failed: ...". Those books need uploading again once the node is back.
- **Login and every other page:** unaffected.

A tester app that boots while the node is down needs #363 to create its collections once the node returns.

## What is lost if the volume is lost

Every tester's search index. Postgres still holds the books and chunks, and the bucket the PDFs, but nothing re-indexes existing rows, and a plain re-upload does not either: ingestion skips a file whose book is already `:completed` for that model (dedup on `file_hash`). Recovery is removing the tester's book rows (or the tester's database) and uploading again. Flagged on #364.

## Capacity (verified locally, synthetic vectors)

With the production mapping (1536-dimension HNSW on faiss, `m: 16`), k-NN's off-heap graph memory was 6,148 KB per 1,000 chunks, about 6.1 KB a chunk; a chunk is roughly a page. k-NN's circuit breaker is half of what the heap leaves, about 1 GB on this machine, which is room for roughly 170,000 chunks across all testers. The node's resident memory was 2.5 GB before any data (the 2 GB heap is touched up front) and 2.6 GB after 10,000 chunks, inside a 4 GB limit. Index size on disk was 131 MB per 10,000 chunks. Watch `graph_memory_usage_percentage`; vectors are the limit long before the heap is.

## Verified locally

A local Docker container on 2026-11-22: the image built from this directory (base digest `sha256:23297b8d…48d2f04b`), a 4 GB memory limit, the `[env]` values and command from `fly.toml`, and a freshly formatted ext4 filesystem (root-owned, `lost+found` at its root) mounted on the data directory. That container also needed `cluster.routing.allocation.disk.threshold_enabled=false`, which is a fact about the test host, not about Fly. None of this checks a box on #364.

| Claim | Local result |
|---|---|
| The stock image cannot use a root-owned mount | `AccessDeniedException: /usr/share/opensearch/data/nodes`; the process stays alive, nothing listens |
| The entrypoint fixes it | `chown 1000:1000` on the mount root only; the node runs as uid 1000 and creates `nodes/` beside `lost+found` |
| Heap | 1 GB without `OPENSEARCH_JAVA_OPTS` on a 4 GB container; 2 GB with it |
| Settings on the command line | `opensearch -Ediscovery.type=single-node -Enetwork.host=_local_,_eth0_` binds `127.0.0.1:9200` and the container's eth0 address; health yellow |
| Durability | 10,000 documents read back after `docker restart`, and again from a new container on the same filesystem |
| Cake can use it | `mix test --only integration test/cake/books/pipeline_integration_test.exs` (the fixture PDFs through the real pipeline): 15 passed |
| `vm.max_map_count` | 65530 on the test host and not writable from the container; the node started and served all of the above anyway |

**Not proved locally: IPv6.** The kernel this ran on has no IPv6 at all, so nothing here shows the node binding the private address. `network.host=_global_` and `network.host=::` both failed to start there, for that reason.

## Fly facts read, not yet verified

Fly's documentation, read 2026-11-22.

- **Private addressing.** `<app>.internal` is an AAAA record holding the private addresses of the app's started machines; no service section and no IP is needed. A process must listen on IPv6 to be reached (`fly-local-6pn`, or `[::]`) (<https://fly.io/docs/networking/private-networking/>, <https://fly.io/docs/networking/app-services/>). `_eth0_` is our choice for "the private IPv6 and the private IPv4 both"; if the first deploy's `bound_address` lacks an `fdaa:` address, the fallbacks are `_local_,_site_,fly-local-6pn` and then `::`.
- **Flycast** needs a service section, a private address (`fly ips allocate-v6 --private`) and a listener on IPv4 `0.0.0.0`; "If you have public IP addresses assigned to your app, then services in `fly.toml` are exposed to the public internet" (<https://fly.io/docs/networking/flycast/>). It is not configured here.
- **No public address.** `fly deploy` allocates public addresses only for an app with an eligible HTTP service that has none yet (<https://fly.io/docs/launch/deploy/>). The docs do not say outright that a service-less app gets zero, hence `--no-public-ips` and `fly ips list`.
- **Health check port.** A top-level check's port "needs to be available on `0.0.0.0`" (<https://fly.io/docs/reference/configuration/>), which is why the node listens on IPv4 as well.
- **`vm.max_map_count`.** The documentation says nothing. Forum reports: the default is 65530; a root process in the machine can raise it, a non-root one cannot (<https://community.fly.io/t/installing-elastic-search-server/4628>). `entrypoint.sh` tries, and logs which happened.
- **Volume ownership.** Undocumented. A 2021 staff post says the mount is chowned to the image's user unless the entrypoint starts as root, in which case it is `root:root` (<https://community.fly.io/t/fly-volumes-getting-permission-denied/1773>). Ours starts as root and chowns it itself, which is right either way.
- **Snapshots.** Daily and kept five days unless `scheduled_snapshots = false` (<https://fly.io/docs/volumes/snapshots/>); `fly.toml` turns them off. The key applies to a volume a deploy creates; check with `fly volumes list`.
- **One machine.** A process group with a volume gets one machine (<https://fly.io/docs/apps/app-availability/>); `--ha=false` says so explicitly.
