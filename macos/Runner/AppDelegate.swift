import Cocoa
import FlutterMacOS
import ServiceManagement

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

/// Mac-only settings: open at login, and living in the menu bar.
final class MacBridge: NSObject {
  static let shared = MacBridge()

  private var statusItem: NSStatusItem?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "photobridge/mac", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      switch call.method {
      case "launchAtLogin":
        result(self.launchAtLogin)
      case "setLaunchAtLogin":
        result(self.setLaunchAtLogin(on))
      case "setMenuBarOnly":
        self.setMenuBarOnly(on)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Null before macOS 13, which has no SMAppService.
  private var launchAtLogin: Bool? {
    guard #available(macOS 13.0, *) else { return nil }
    return SMAppService.mainApp.status == .enabled
  }

  /// Returns the new state, or an error message.
  private func setLaunchAtLogin(_ on: Bool) -> Any? {
    guard #available(macOS 13.0, *) else { return nil }
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      return SMAppService.mainApp.status == .enabled
    } catch {
      return FlutterError(code: "login", message: error.localizedDescription, details: nil)
    }
  }

  private func setMenuBarOnly(_ on: Bool) {
    if on {
      if statusItem == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
          systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "PhotoBridge")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open PhotoBridge", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PhotoBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
      }
      NSApp.setActivationPolicy(.accessory)
    } else {
      if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
      statusItem = nil
      NSApp.setActivationPolicy(.regular)
    }
  }

  @objc private func openWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
  }
}
