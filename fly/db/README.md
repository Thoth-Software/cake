# Runbook: `cake-staging-db`, the shared staging Postgres

The Postgres every tester app shares (#365, part of the staging epic #360). It is the official `postgres:14` image on one Fly machine with one volume, run by us. There is no pooler, no replica and no backup. Each tester gets one database and one role that owns it. `fly.toml` beside this file is the whole configuration; there is no init script and no Dockerfile.

**Status: not deployed.** Nothing in this file has been run against Fly yet. "Verified locally" below means a local Docker container; "not yet verified" means read in Fly's documentation and not tried. The (verify) boxes on #365 are checked only from the live app.

## First deploy

Run from the repository root. Roughly $8.20 a month in `iad` (machine $6.70 + 10 GB volume $1.50; Fly's pricing page, 2026-11-22).

```sh
fly apps create cake-staging-db --org <org>

# The superuser password: typed at a hidden prompt and passed on stdin, so it
# is in no command's arguments and not in shell history. Keep a copy in the
# password manager: Fly never shows a secret's value again.
read -rs PW && printf 'POSTGRES_PASSWORD=%s\n' "$PW" | fly secrets import --stage -a cake-staging-db; unset PW

fly deploy -c fly/db/fly.toml --no-public-ips --ha=false
```

The image reads `POSTGRES_PASSWORD` once, when it initialises an empty volume. Changing the secret later does not change the password; use `\password postgres` in `psql`, then update the secret to match.

`primary_region` in `fly.toml` is `iad` as a placeholder. Set it to the region the tester apps and `cake-staging-search` use before the first deploy: a volume cannot move regions.

## How to connect

Every connection needs a password, including the unix socket inside the machine.

- **From a tester app** (same organisation, private network):
  `DATABASE_URL=ecto://<tester>:<password>@cake-staging-db.internal:5432/<tester>` with `ECTO_IPV6=true`. The private network is IPv6 only; `config/runtime.exs` adds `:inet6` to the Repo's socket options when `ECTO_IPV6` is `true` or `1`.
- **From your own machine**, as the superuser: `fly proxy 15432:5432 -a cake-staging-db` in one terminal, then `psql -h localhost -p 15432 -U postgres` in another.
- **On the machine itself**: `fly ssh console -a cake-staging-db`, then `psql -U postgres`.

## Tester databases

Names come from the tester's name; keep them to lowercase letters, digits and underscores so they need no quoting.

List them, with owner and who may connect:

```sql
SELECT d.datname, r.rolname AS owner, d.datacl
FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
WHERE NOT d.datistemplate ORDER BY 1;
```

Add one, as the superuser (`\password` prompts, so the password is not in the statement):

```sql
CREATE ROLE alice LOGIN;
\password alice
CREATE DATABASE alice OWNER alice;
REVOKE CONNECT ON DATABASE alice FROM PUBLIC;
```

The `REVOKE` is what keeps other testers out. Without it any role can connect to any database, since `PUBLIC` holds `CONNECT` on a new database by default. The owner keeps access through ownership. Nothing else is needed: the tester role creates `citext` itself when the first migration runs (trusted extension, no superuser).

Once, after the first deploy, close the maintenance database to tester roles as well:

```sql
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
```

Remove a tester (stop their app first, or `DROP DATABASE` waits on its connections):

```sql
DROP DATABASE alice;
DROP ROLE alice;
```

#368's provision and teardown scripts are expected to wrap these statements.

## What is lost if the volume is lost

Everything in Postgres, for every tester at once: logins, the record of uploaded books and their chunks, parsed documents, failed-ingest records and Oban's job table. The uploaded PDFs themselves are in the staging bucket and the search index is on `cake-staging-search`; neither is touched, but both are orphaned without the rows that point at them.

Recovery is re-provisioning: deploy onto a new volume, recreate each tester's role and database, let each tester app migrate, recreate the logins, and upload the PDFs again. Destroying the machine alone loses nothing; the data is on the volume, and a new machine on the same volume skips initialisation.

## Snapshots (not yet verified)

"No backups" needs one qualification. Fly's documentation, read 2026-11-22:

- "We automatically take daily snapshots of all Fly Volumes. We store snapshots for 5 days by default, but you can set volume snapshot retention from 1 to 60 days." (<https://fly.io/docs/volumes/snapshots/>)
- `[mounts]` takes `snapshot_retention` and `scheduled_snapshots`; the latter "Enable or disable automatic daily snapshots for a volume. The default is true (enabled) when unset." (<https://fly.io/docs/reference/configuration/>). The retention set in `fly.toml` applies to volumes a deploy creates; an existing volume is changed with `fly volumes update`.
- Snapshots cost $0.08/GB/month on data stored, "First 10GB free each month". (<https://fly.io/docs/about/pricing/>)

`fly.toml` leaves both keys unset, so by that documentation this volume gets a daily snapshot kept five days, at no cost at this size. We do not rely on them: a snapshot is taken of a running database's disk, nobody has restored one, and five days is the whole window. To confirm on the live app: `fly volumes list -a cake-staging-db`, then `fly volumes snapshots list <volume id>` a day after the first deploy.

## Other Fly facts read, not yet verified

- **No public address.** "No services section (and no http_service section): The application cannot be reached from the public internet, nor by a Flycast address; this is typical of apps that talk only over 6PN private networking" (<https://fly.io/docs/reference/configuration/>). The docs do not say outright that such an app is allocated zero addresses, so the deploy passes `--no-public-ips` and `fly ips list -a cake-staging-db` is the proof.
- **Private addressing.** The private network is IPv6 over WireGuard and always on. `<app>.internal` resolves to the private addresses of the app's running machines. A service is reachable there if it binds `fly-local-6pn` or the IPv6 wildcard `[::]` (<https://fly.io/docs/networking/private-networking/>, <https://fly.io/docs/networking/app-services/>). The image's `listen_addresses = '*'` includes `[::]`. Flycast is not needed.
- **One machine.** `fly deploy` "creates and starts only one Machine if the process group has volumes mounted" (<https://fly.io/docs/reference/app-availability/>); `--ha=false` says so explicitly.
- **The volume.** Created by the first `fly deploy` from `[mounts]` at `initial_size`, encrypted at rest by default. The reference page is not consistent on auto-creation; if the deploy asks for the volume, `fly volumes create pgdata --size 10 -r <region> -a cake-staging-db` first.
- **`lost+found`.** Only Fly's MySQL guide mentions it ("That's why you need to use a subdirectory of the mounted location"); it is the reason for `PGDATA`.

## Verified locally

All of these came from a local Docker container on 2026-11-22: `postgres:14` (PostgreSQL 14.25, `sha256:c0e9c0e9…e24b059`), the two `[env]` values from `fly.toml`, a mounted volume with `lost+found` at its root, and a second container on the same Docker network as the client. None of them checks a box on #365.

| Claim | Local result |
|---|---|
| `PGDATA` in a subdirectory of the mount | `data_directory` is `/var/lib/postgresql/data/pgdata`; the mount root holds `lost+found` and `pgdata` |
| scram for every connection | All seven `pg_hba` rules are `scram-sha-256`; the superuser's stored password is a `SCRAM-SHA-256` verifier |
| Refused without the password | `fe_sendauth: no password supplied` over TCP from the other container, over loopback and over the unix socket; `password authentication failed` with a wrong one |
| A tester role creates `citext` without superuser | `CREATE EXTENSION` succeeded as a role with no superuser, createdb or createrole; the extension's owner is that role |
| A tester cannot reach another tester's database | `permission denied for database "bob"`, `User does not have CONNECT privilege`, in both directions. Control: a database created without the `REVOKE` let the other tester in |
| A row survives a restart | Read back after `docker restart`, and again from a new container on the same volume ("Skipping initialization") |
| Cake's migrations run as the tester role | `MIX_ENV=prod mix ecto.migrate` through `DATABASE_URL`: all 13 migrations, `citext` and all 10 tables owned by the tester |

**Not proved locally: IPv6.** The kernel this was run on has no IPv6 at all (`Address family not supported by protocol`), so Postgres logged `could not create IPv6 socket for address "::"` and listened on IPv4 only, and the migrations ran without `ECTO_IPV6`. What was seen is the configuration that should produce it (`listen_addresses = '*'`, and a `host all all all scram-sha-256` rule that covers IPv6 clients). Box 2 on the live app is the first real test.
