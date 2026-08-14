# Calculator Web (Cluster Worker Pool + Event-Sourced History)

- Built-in `DistributedCluster.WorkerPool` for calculation dispatch
- Workers run on separate cluster node(s) and register via receptionist
- History is event-sourced via `ClusterJournalPlugin` + `EventSourced` virtual actor (`Calculator`)
- Per-client actor identity is enforced by virtual actor id (`calculator-history-<clientId>`)
- Web is HTMX + `Elementary` via `HummingbirdElementary`

## Node Modes

`calculator-web` executable supports:

- `seed`: runs the cluster daemon (seed node) role
- `frontend`: runs web app + worker pool router (no local virtual actor hosting)
- `client`: runs virtual actor hosting node for `Calculator` entities
- `worker`: runs calculation workers on a separate node
- `standalone`: runs seed + frontend + client + worker nodes together for local demo

## Standalone vs. separate nodes

- `standalone` — seed + frontend + client + worker all in one process. Easiest way to try the demo, but killing the process kills the whole cluster, so a crash test means restarting everything.
- Separate processes (`seed`, `frontend`, `client`, `worker`, one per terminal) — nodes discover each other via the cluster daemon hosted by the `seed` process. This is the mode that actually demonstrates "let it crash": kill the `client` node and restart it, and the `Calculator` actor's history is recovered from the event store while the rest of the cluster stays up.

Postgres is optional. Pass `--database-url` (or set `DATABASE_URL`) to store events in Postgres:

```bash
swift run calculator-web standalone --database-url postgres://postgres:postgres@localhost:5432/calculator
```

Without it, every node falls back to a file-based store under `~/Library/Application Support/calculator-web/journal/` (one `.jsonl` file per actor) — events still survive restarts, so crash recovery works the same. Note that in separate-nodes mode all processes must run on the same machine for the file fallback to share the journal. TLS is off by default for local development; set `DB_TLS=true` to require it.

## Run (standalone)

```bash
swift run calculator-web standalone
```

## Run (separate nodes)

Start seed node first:

```bash
swift run calculator-web seed
```

Start frontend:

```bash
swift run calculator-web frontend
```

Start client node (separate terminal):

```bash
swift run calculator-web client
```

Start worker node (separate terminal):

```bash
swift run calculator-web worker --port 3652
```

Default cluster bindings are fixed:
- `frontend` -> `127.0.0.1:3650`
- `client` -> `127.0.0.1:3651`

Open: `http://127.0.0.1:8080/`

## Routes

- `GET /` — client selection, or calculator + history with `?clientId=<int>`
- `POST /calculate` — form params: `clientId`, `lhs`, `rhs`, `op` (`add`/`sub`/`mul`/`div`)
