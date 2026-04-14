import DistributedCluster
import SeamlessBackend
import ServiceLifecycle
import SharedModels

struct WorkersNode: Service {
  func run() async throws {
    let actorSystem = await ClusterSystem("emoji-reactions-node") {
      $0.bindPort = 4670
      $0.discovery = .clusterd
      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    }
    var workers: [ResponseWorker<EmojiReaction>] = []
    for _ in 0...4 {
      workers.append(try await ResponseWorker(actorSystem: actorSystem))
    }
    try await actorSystem.terminated
  }
}
