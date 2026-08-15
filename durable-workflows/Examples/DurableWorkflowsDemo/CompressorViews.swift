import DurableWorkflows
import Elementary
import ElementaryHTMX
import ElementaryHTMXSSE
import FileCompressor
import Foundation

struct CompressorEntryPage: HTMLDocument, Sendable {
  var title: String { "File Compressor" }

  var head: some HTML {
    meta(.charset(.utf8))
    meta(.name("viewport"), .content("width=device-width, initial-scale=1"))
    link(.href("/style.css"), .rel(.stylesheet))
  }

  var body: some HTML {
    main(.class("container")) {
      section(.class("card"), .style("max-width: 500px; margin: 4rem auto; text-align: center;")) {
        h2 { "File Compressor" }
        p { "Enter a session ID to start or resume a compression." }
        form(.action("/compressor/session"), .method(.get), .style("margin-top: 2rem;")) {
          div(.style("display: flex; flex-direction: column; gap: 1rem;")) {
            input(
              .type(.text),
              .name("id"),
              .placeholder("my-session"),
              .required,
              .style("text-align: center; font-family: monospace;")
            )
            button(.type(.submit)) { "Enter" }
          }
        }
      }
    }
  }
}

struct CompressorSessionPage: HTMLDocument, Sendable {
  let sessionId: String
  var hasWorkflow: Bool = false
  var title: String { "File Compressor – \(sessionId)" }

  var head: some HTML {
    meta(.charset(.utf8))
    meta(.name("viewport"), .content("width=device-width, initial-scale=1"))
    link(.href("/style.css"), .rel(.stylesheet))
    script(.src("https://unpkg.com/htmx.org@2.0.3")) {}
    script(.src("https://unpkg.com/htmx-ext-sse@2.2.2/sse.js")) {}
  }

  var body: some HTML {
    main(.class("container")) {
      header {
        h1 { "File Compressor" }
        p(.style("opacity: 0.7;")) {
          "Session: "
          code { sessionId }
        }
      }
      div(.id("main-app")) {
        CompressorFormFragment(sessionId: sessionId, hasWorkflow: hasWorkflow)
      }
    }
  }
}

private struct URLListField: HTML, Sendable {
  var body: some HTML {
    div {
      div(.id("url-list"), .style("display: flex; flex-direction: column; gap: 0.5rem; margin-bottom: 0.5rem;")) {
        div(.style("display: flex; gap: 0.5rem;")) {
          input(
            .type(.text),
            .name("url"),
            .placeholder("https://example.com/file.txt"),
            .required,
            .style("flex: 1; font-family: monospace; font-size: 0.9rem;")
          )
          button(
            .type(.button),
            .on(.click, URLListScript.removeURL),
            .style("background: var(--danger); color: white; border: none; padding: 0.5rem 0.75rem; border-radius: 8px; cursor: pointer; flex-shrink: 0;")
          ) { "✕" }
        }
      }
      button(
        .type(.button),
        .on(.click, URLListScript.addURL),
        .style("width: 100%; background: transparent; color: var(--primary); border: 1px dashed var(--primary); font-weight: 600;")
      ) { "+ Add URL" }
    }
  }
}

private struct ArchiveNameField: HTML, Sendable {
  var body: some HTML {
    div {
      label(.style("display: block; margin-bottom: 0.4rem; font-weight: 500;")) { "Archive name" }
      input(
        .type(.text),
        .name("archiveName"),
        .placeholder("archive"),
        .value("archive"),
        .style("width: 100%; box-sizing: border-box;")
      )
    }
  }
}

private enum URLListScript {
  static let addURL = "addUrl()"
  static let removeURL = "this.parentElement.remove(); syncRemoveButtons();"

  static let source = """
    function addUrl() {
      const list = document.getElementById('url-list');
      const row = document.createElement('div');
      row.style.cssText = 'display:flex;gap:0.5rem;';
      const input = document.createElement('input');
      input.type = 'text';
      input.name = 'url';
      input.placeholder = 'https://example.com/file.txt';
      input.style.cssText = 'flex:1;font-family:monospace;font-size:0.9rem;padding:0.75rem;border-radius:8px;border:1px solid #e5e7eb;';
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.textContent = '✕';
      btn.style.cssText = 'background:var(--danger);color:white;border:none;padding:0.5rem 0.75rem;border-radius:8px;cursor:pointer;flex-shrink:0;';
      btn.onclick = () => { row.remove(); syncRemoveButtons(); };
      row.appendChild(input);
      row.appendChild(btn);
      list.appendChild(row);
      syncRemoveButtons();
    }
    function syncRemoveButtons() {
      const rows = document.querySelectorAll('#url-list > div');
      rows.forEach(row => {
        const btn = row.querySelector('button');
        if (btn) btn.style.display = rows.length > 1 ? '' : 'none';
      });
    }
    document.addEventListener('DOMContentLoaded', syncRemoveButtons);
    """
}

struct CompressorFormFragment: HTML, Sendable {
  let sessionId: String
  var hasWorkflow: Bool = false

  var body: some HTML {
    section(.class("card")) {
      h2 { "Add URLs" }
      form(
        .hx.post("/compressor/compress/\(sessionId)"),
        .hx.target("#workflow-status"),
        .hx.swap(.innerHTML)
      ) {
        div(.style("display: flex; flex-direction: column; gap: 1rem;")) {
          URLListField()
          ArchiveNameField()
          button(.type(.submit)) { "Compress" }
        }
      }
      script { HTMLRaw(URLListScript.source) }
    }
    div(.id("workflow-status"), .style("margin-top: 2rem;")) {
      if hasWorkflow {
        CompressorStatusContainer(workflowId: sessionId)
      }
    }
    section(.class("card"), .style("border-color: var(--danger); text-align: center; margin-top: 2rem;")) {
      h2(.style("color: var(--danger)")) { "Durability Test" }
      p { "Crash the server mid-fetch and restart — the workflow resumes from the last completed file." }
      button(.class("btn-danger"), .hx.post("/crash")) { "💥 Crash Server" }
    }
  }
}

/// SSE container: returned once by POST /compressor/compress, maintains the connection.
struct CompressorStatusContainer: HTML, Sendable {
  let workflowId: String

  var body: some HTML {
    div(
      .id("stream-\(workflowId)"),
      .hx.ext(.sse),
      .sse.connect("/compressor/stream/\(workflowId)"),
      .sse.close("done")
    ) {
      // Placeholder must carry sse-swap so the first SSE update has a target to replace.
      div(.class("card"), .id("status-\(workflowId)"), .sse.swap("update"), .hx.swap(.outerHTML)) {
        p { "Starting..." }
      }
    }
  }
}

/// Status card: sent as SSE updates and also returned by GET /compressor/status/:id.
struct CompressorStatusCard: HTML, Sendable {
  let workflowId: String
  let info: WorkflowStatusInfo
  let urls: [URL]
  var downloadFractions: [Int: Double] = [:]

  var body: some HTML {
    div(
      .class("card"),
      .id("status-\(workflowId)"),
      .sse.swap("update"),
      .hx.swap(.outerHTML)
    ) {
      div(.style("display: flex; justify-content: space-between; align-items: start; margin-bottom: 1rem;")) {
        div {
          h3(.style("margin: 0;")) { statusTitle }
          code(.style("opacity: 0.6; font-size: 0.8rem;")) { workflowId }
        }
        span(.class("badge \(badgeClass)")) { info.status.name }
      }

      if !urls.isEmpty {
        FileProgressSection(
          urls: urls,
          events: info.events,
          isRunning: info.status == .running,
          downloadFractions: downloadFractions
        )
      }

      if case .completed(let data) = info.status,
        let result = try? JSONDecoder().decode(FileCompressorWorkflow.Output.self, from: data)
      {
        div(.style("padding: 1rem; background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 10px; margin-bottom: 1rem;")) {
          p(.style("margin: 0;")) {
            "✅ Archive ready: "
            a(.href("/compressor/download/\(workflowId)")) {
              code { result.archivePath.split(separator: "/").last.map(String.init) ?? "archive.zip" }
            }
          }
        }
      }

      div(.class("history-list")) {
        ForEach(info.events.reversed()) { event in
          div(.class("history-item")) {
            renderEvent(event)
          }
        }
      }
    }
  }

  private var statusTitle: String {
    switch info.status {
    case .running: return "Compressing..."
    case .completed: return "Compression complete"
    case .failed: return "Compression failed"
    case .cancelled: return "Cancelled"
    case .idle: return "Queued"
    }
  }

  private var badgeClass: String {
    switch info.status {
    case .completed: return "badge-success"
    case .failed: return "badge-danger"
    case .running: return "badge-info"
    case .cancelled: return "badge-warning"
    default: return "badge-info"
    }
  }

  @HTMLBuilder
  private func renderEvent(_ event: WorkflowEvent) -> some HTML {
    switch event {
    case .executionStarted:
      span { "🚀 Workflow started" }
    case .activitySucceeded(let key, _):
      span {
        "✅ "
        strong { key.name }
      }
    case .activityFailed(let key, let fail):
      span(.style("color: var(--danger)")) {
        "❌ "
        strong { key.name }
        " — \(fail.message)"
      }
    case .timerScheduled(_, let duration, _, let summary):
      span { "⏲️ Timer set: \(duration)\(summary.map { " (\($0))" } ?? "")" }
    case .timerFired:
      span { "⏰ Timer fired" }
    case .timerCancelled:
      span { "🕑 Timer cancelled" }
    case .timestampRecorded(_, let date):
      span { "🕓 Time recorded: \(date)" }
    case .executionCompleted:
      span(.style("color: var(--success)")) { "🏁 Done" }
    case .executionCancelled:
      span { "🛑 Cancelled" }
    case .executionFailed(let msg):
      span(.style("color: var(--danger)")) { "💥 \(msg)" }
    case .retryPolicyConfigured:
      span { "🔁 Automatic retry enabled" }
    case .retryScheduled(let attempt, let deadline):
      span { "🔁 Retry #\(attempt) scheduled at \(deadline)" }
    }
  }
}

// MARK: - Per-file progress

private enum FileState { case pending, fetching, done, failed }

private struct FileProgressSection: HTML, Sendable {
  let urls: [URL]
  let events: [WorkflowEvent]
  let isRunning: Bool
  var downloadFractions: [Int: Double] = [:]

  private struct IndexOnly: Decodable { let index: Int }

  // The activity key carries the encoded input — decode it directly instead
  // of reverse-engineering a string format.
  private func fileIndex(from key: ActivityKey) -> Int? {
    try? JSONDecoder().decode(IndexOnly.self, from: key.inputData).index
  }

  // Last known state per index (succeeded wins over failed if both present)
  private var stateByIndex: [Int: FileState] {
    var result: [Int: FileState] = [:]
    for event in events {
      switch event {
      case .activitySucceeded(let key, _):
        if let i = fileIndex(from: key), i < urls.count { result[i] = .done }
      case .activityFailed(let key, _):
        if let i = fileIndex(from: key), i < urls.count, result[i] != .done { result[i] = .failed }
      default: break
      }
    }
    return result
  }

  private func state(for index: Int, resolved: [Int: FileState]) -> FileState {
    if let s = resolved[index] { return s }
    return isRunning ? .fetching : .pending
  }

  var body: some HTML {
    let resolved = stateByIndex
    let doneCount = resolved.values.filter { $0 == .done }.count
    let pct = doneCount * 100 / urls.count

    div(.style("margin-bottom: 1.5rem;")) {
      div(.style("display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.4rem;")) {
        span(.style("font-weight: 500; font-size: 0.9rem;")) { "Files" }
        span(.style("opacity: 0.6; font-size: 0.85rem;")) { "\(doneCount) / \(urls.count)" }
      }
      div(.style("height: 4px; background: var(--line); border-radius: 2px; margin-bottom: 0.75rem;")) {
        div(.style("height: 100%; width: \(pct)%; background: var(--primary); border-radius: 2px;")) {}
      }
      div(.style("display: flex; flex-direction: column; gap: 0.3rem;")) {
        ForEach(urls.enumerated()) { index, url in
          FileProgressRow(url: url, state: state(for: index, resolved: resolved), downloadFraction: downloadFractions[index])
        }
      }
    }
  }
}

private struct FileProgressRow: HTML, Sendable {
  let url: URL
  let state: FileState
  var downloadFraction: Double? = nil

  private var icon: String {
    switch state {
    case .done: return "✅"
    case .fetching: return "⏳"
    case .failed: return "❌"
    case .pending: return "○"
    }
  }

  private var name: String {
    let last = url.lastPathComponent
    return last.isEmpty ? url.absoluteString : last
  }

  var body: some HTML {
    div(.style("display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.85rem;")) {
      div(.style("display: flex; align-items: center; gap: 0.5rem;")) {
        span { icon }
        span(.style("flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: monospace; opacity: 0.8;")) { name }
        if state == .fetching, let fraction = downloadFraction {
          span(.style("opacity: 0.6; font-size: 0.8rem; flex-shrink: 0;")) { "\(Int(fraction * 100))%" }
        }
      }
      if state == .fetching, let fraction = downloadFraction {
        div(.style("height: 3px; background: var(--line); border-radius: 2px;")) {
          div(.style("height: 100%; width: \(Int(fraction * 100))%; background: var(--primary); border-radius: 2px; transition: width 0.3s;")) {}
        }
      }
    }
  }
}
