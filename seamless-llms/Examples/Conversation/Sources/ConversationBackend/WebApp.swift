import ConversationWebApp
import DistributedCluster
import Foundation
import Hummingbird
import HummingbirdWebSocket
import SeamlessBackend
import SeamlessClient
import ServiceLifecycle
import SharedModels

struct WebApp: Service {

  let host: String
  let httpPort: Int
  let webPort: Int

  func run() async throws {
    let client = try SeamlessClient(
      configuration: .init(target: .remote(URL(string: "http://\(host):\(httpPort)")!))
    )
    let router = Router(context: BasicWebSocketRequestContext.self)
    router.addMiddleware {
      FileMiddleware(WebAppAssets.publicRoot, searchForIndexHtml: false)
    }
    WebAppRoutes(client: client).register(on: router)
    let app = Application(
      router: router,
      server: .http1WebSocketUpgrade(webSocketRouter: router),
      configuration: .init(address: .hostname(host, port: webPort))
    )
    try await app.run()
  }
}
