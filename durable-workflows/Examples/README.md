# Durable Workflows Examples

Two demo applications showing durable workflows in action:

- **Travel Booking** — a saga: reserve funds → book flight → book hotel → capture payment, with automatic compensation on failure.
- **File Compressor** — downloads files and archives them into a zip, with live progress over SSE.

The app runs a local web UI at `http://localhost:8080` (landing page links to both demos). In Travel Booking, multiple browser tabs can connect as different users. Clicking **Crash Server** mid-booking demonstrates durability — restart the server and the workflow resumes from where it left off.

![Booking example](booking-example.png)

## Architecture

```
Browser (HTMX + WebSockets)
    ↕
Hummingbird HTTP/WS server
    ↕
UserActor (balance, booking state)
    ↕
WorkflowActor<TravelBookingWorkflow> (workflow state)
    ↕
DurableActivityDispatchWorker  →  TravelBookingActivities
```

## Requirements

- Swift 6.2+
- macOS 26+
- (optional) PostgreSQL for persistent storage across restarts

## Setup — File Storage (no database needed)

```bash
cd Examples
swift run durable-workflows-demo
```

Events are stored in `~/Library/Application Support/durable-workflows/journal/` as `.jsonl` files — one per actor. This is the easiest way to try the demo and test crash recovery.

Open `http://localhost:8080` in your browser.

## Testing Crash Recovery

> [!NOTE]
> The demo runs everything in a single process — the cluster daemon, the node hosting `UserActor`/workflow actors, the activity workers, and the web server (standalone style). A "crash" therefore restarts the whole world: durability is demonstrated by the event log surviving the restart, not by other nodes staying up. The building blocks (`ClusterSystem.startClusterDaemon`, `.clusterd` discovery, separate worker nodes) all support splitting roles across processes if you want real node failure.

1. Open `http://localhost:8080`, enter a username, open the dashboard.
2. Click **Book Trip Now** and click **Crash Server** before the booking finishes.
3. Restart the server with the same command.
4. Refresh the dashboard — the workflow resumes and completes from the last persisted activity.

With **file storage** the journal persists across restarts automatically.
With **Postgres** data survives even if the journal directory is wiped.

## Project Structure

```
Examples/
├── Package.swift                   # standalone Swift package
├── EventStores/
│   └── FileEventStore.swift        # file-based EventStore implementation
├── FileCompressor/
│   ├── FileCompressorWorkflow.swift
│   ├── FileCompressorActivities.swift
│   └── CompressorSession.swift     # Compressor virtual actor + Connection
├── TravelBooking/
│   ├── TravelBookingWorkflow.swift # saga: reserve → book → capture / compensate
│   ├── TravelBookingActivities.swift
│   ├── User.swift                  # UserActor: balance, holds, WS broadcast
│   ├── Models.swift
│   ├── BookingMessage.swift
│   └── Connection.swift
└── DurableWorkflowsDemo/
    ├── App.swift                   # CLI entry point, HTTP/WS/SSE server
    ├── Views.swift                 # Travel Booking Elementary components
    ├── CompressorViews.swift       # File Compressor Elementary components
    ├── StreamConnections.swift     # WebSocket session management
    └── Public/                     # static assets (CSS, JS)
```

## CLI Options

```
USAGE: durable-workflows-demo [--database-url <url>]

OPTIONS:
  --database-url <url>   PostgreSQL connection URL.
                         If omitted, uses file-based storage.
  -h, --help             Show help information.
```
