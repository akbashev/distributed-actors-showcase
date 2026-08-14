import Foundation

public struct WebAppAssets {
  public static var publicRoot: String {
    Bundle.module.resourceURL!.appendingPathComponent("Public").path
  }
}
