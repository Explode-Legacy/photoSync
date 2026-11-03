import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override init() {
    super.init()
    // Files opened before Flutter is up wait in SharedFiles until asked for.
    addApplicationLifecycleDelegate(SharedFiles.shared)
  }

  // Keep syncing with the window closed; the Dock icon brings it back.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { mainFlutterWindow?.makeKeyAndOrderFront(nil) }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Files and folders dropped on the Dock icon or opened with "Open With →
/// PhotoBridge" in Finder, handed to Dart on request (`takeShared`).
final class SharedFiles: NSObject, FlutterAppLifecycleDelegate {
  static let shared = SharedFiles()

  private var channel: FlutterMethodChannel?
  private var pending: [String] = []

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "photobridge/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "takeShared" else { return result(FlutterMethodNotImplemented) }
      result(self.pending)
      self.pending = []
    }
    self.channel = channel
  }

  func handleOpen(_ urls: [URL]) -> Bool {
    let paths = urls.filter(\.isFileURL).map(\.path)
    guard !paths.isEmpty else { return false }
    pending += paths
    channel?.invokeMethod("sharedAvailable", arguments: nil)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
    return true
  }
}
