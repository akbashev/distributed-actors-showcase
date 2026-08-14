# Calculator Web (Cluster Worker Pool + Event-Sourced History)

- Built-in `DistributedCluster.WorkerPool` for calculation dispatch
- Workers run on separate cluster node(s) and register via receptionist
- History is event-sourced via `ClusterJournalPlugin` + `EventSourced` virtual actor (`Client`)
- Per-client actor identity is enforced by virtual actor id (`client-<id>`)
- Web is HTMX + `Elementary` via `HummingbirdElementary`

## Node Modes

`calculator-web` executable supports:

- `daemon`: runs cluster daemon (`clusterd`) inside the same binary
- `frontend`: runs web app + worker pool router (no local virtual actor hosting)
- `client`: runs virtual actor hosting node for `Client` entities
- `worker`: runs calculation workers on a separate node
- `standalone`: runs daemon + frontend + client + worker nodes together for local demo

## Run (two nodes)

Start daemon first:

```bash
swift run calculator-web daemon
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

Open: `http://127.0.0.1:8080/app`

## Routes

- `GET /app`
- `POST /app/connect`
- `POST /app/calculate`
- `GET /app/history?client_id=<int>`
