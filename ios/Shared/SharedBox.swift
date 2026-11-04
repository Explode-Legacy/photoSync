import Foundation

/// The folder PhotoBridge and its Share extension both see (an App Group),
/// used to hand shared photos and files to the app.
///
/// - `devices.json`: the app's paired devices, so the share sheet can list
///   them.
/// - `outbox/<job>/`: files shared from another app, plus `job.json` with the
///   chosen device ids. The app sends them, then removes the job.
enum SharedBox {
  /// Posted (Darwin notification) when the extension adds a job.
  static let outboxNotification = "com.photobridge.outbox"

  /// SideStore/AltStore rename app groups when they sign the app, and list
  /// the real ones under ALTAppGroups; try those first, then the names the
  /// group would have after their renaming, then the original.
  static let container: URL? = {
    var candidates: [String] = []
    if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
      candidates += groups
    }
    if var id = Bundle.main.bundleIdentifier {
      // The extension's id is the app's id plus ".ShareExtension".
      if id.hasSuffix(".ShareExtension") { id.removeLast(".ShareExtension".count) }
      candidates.append("group.\(id)")
    }
    candidates.append("group.com.photobridge.app5ymxh")
    for group in candidates {
      if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
        return url
      }
    }
    return nil
  }()

  static var devicesFile: URL? { container?.appendingPathComponent("devices.json") }
  static var outbox: URL? { container?.appendingPathComponent("outbox", isDirectory: true) }
}
