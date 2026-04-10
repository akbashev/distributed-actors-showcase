# Travel Booking Example

A demo application showing durable workflows in action with a travel booking saga: reserve funds → book flight → book hotel → capture payment, with automatic compensation on failure.

The app runs a local web UI at `http://localhost:8080`. Multiple browser tabs can connect as different users. Clicking **Crash Server** mid-booking demonstrates durability — restart the server and the workflow resumes from where it left off.

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
├── TravelBooking/
│   ├── TravelBookingWorkflow.swift # saga: reserve → book → capture / compensate
│   ├── TravelBookingActivities.swift
│   ├── User.swift                  # UserActor: balance, holds, WS broadcast
│   ├── Models.swift
│   ├── BookingMessage.swift
│   └── Connection.swift
└── DurableWorkflowsDemo/
    ├── App.swift                   # CLI entry point, HTTP/WS server
    ├── FileEventStore.swift        # file-based EventStore implementation
    ├── Views.swift                 # Elementary HTML components
    ├── StreamConnections.swift     # WebSocket session management
    └── Public/                     # static assets (CSS, JS)
```

## CLI Options

```
USAGE: demo [--database-url <url>]

OPTIONS:
  --database-url <url>   PostgreSQL connection URL.
                         If omitted, uses file-based storage.
  -h, --help             Show help information.
```
