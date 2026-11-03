import BackgroundTasks
import Flutter
import UIKit
import UniformTypeIdentifiers
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let continued = ContinuedSync()
  private let files = FilesBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Headless engines for background tasks need the plugins too.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Must match kIosRefreshTask / kIosProcessingTask in ios_background.dart.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.photobridge.app5ymxh.refresh",
      frequency: NSNumber(value: 15 * 60)
    )
    WorkmanagerPlugin.registerBGProcessingTask(
      withIdentifier: "com.photobridge.app5ymxh.processing"
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhotoBridgeBackground") {
      continued.attach(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhotoBridgeFiles") {
      files.attach(messenger: registrar.messenger())
      // Delivers files from the share sheet ("Open in PhotoBridge").
      registrar.addSceneDelegate(files)
    }
  }
}

/// Keeps a running sync alive after the user leaves the app.
///
/// iOS 26+: a BGContinuedProcessingTask, which iOS shows with a progress
/// Live Activity. Older iOS: the standard background grace period (~30s).
final class ContinuedSync {
  private static let identifierPrefix = "com.photobridge.app5ymxh.continued"

  private var channel: FlutterMethodChannel?
  private var legacyTask: UIBackgroundTaskIdentifier = .invalid
  private var total: Int64 = 0
  private var done: Int64 = 0
  // Typed as Any so this compiles against older SDK availability checks.
  private var task: Any?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "photobridge/background", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "begin":
        self.begin(total: (args["total"] as? NSNumber)?.int64Value ?? 0)
      case "progress":
        self.progress(
          done: (args["done"] as? NSNumber)?.int64Value ?? 0,
          total: (args["total"] as? NSNumber)?.int64Value ?? 0
        )
      case "end":
        self.end(sent: (args["sent"] as? NSNumber)?.intValue ?? 0)
      default:
        return result(FlutterMethodNotImplemented)
      }
      result(nil)
    }
    self.channel = channel
  }

  private func begin(total: Int64) {
    self.total = total
    self.done = 0
    beginLegacy()
    if #available(iOS 26.0, *) { beginContinued() }
  }

  @available(iOS 26.0, *)
  private func beginContinued() {
    let id = "\(Self.identifierPrefix).\(UUID().uuidString)"
    BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] bgTask in
      guard let self, let bgTask = bgTask as? BGContinuedProcessingTask else {
        bgTask.setTaskCompleted(success: false)
        return
      }
      self.task = bgTask
      bgTask.progress.totalUnitCount = max(self.total, 1)
      bgTask.progress.completedUnitCount = self.done
      bgTask.expirationHandler = { [weak self] in
        self?.channel?.invokeMethod("expired", arguments: nil)
        bgTask.setTaskCompleted(success: false)
        self?.task = nil
      }
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: id,
      title: "Sending photos",
      subtitle: "To your other phone"
    )
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Not allowed right now (e.g. too many running); the legacy grace
      // period still applies.
    }
  }

  private func progress(done: Int64, total: Int64) {
    self.done = done
    self.total = total
    if #available(iOS 26.0, *), let bgTask = task as? BGContinuedProcessingTask {
      bgTask.progress.totalUnitCount = max(total, 1)
      bgTask.progress.completedUnitCount = done
      bgTask.updateTitle("Sending photos", subtitle: "\(done) of \(total)")
    }
  }

  private func end(sent: Int) {
    if #available(iOS 26.0, *), let bgTask = task as? BGContinuedProcessingTask {
      bgTask.progress.completedUnitCount = bgTask.progress.totalUnitCount
      bgTask.setTaskCompleted(success: true)
    }
    task = nil
    endLegacy()
  }

  private func beginLegacy() {
    guard legacyTask == .invalid else { return }
    legacyTask = UIApplication.shared.beginBackgroundTask(withName: "PhotoBridgeSync") { [weak self] in
      self?.endLegacy()
    }
  }

  private func endLegacy() {
    guard legacyTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(legacyTask)
    legacyTask = .invalid
  }
}

/// "Send files" support: a folder picker, and files shared to PhotoBridge.
///
/// Folder picker: file_picker returns a picked folder's path without opening
/// access to it, so files in iCloud Drive or other apps' folders can't be
/// read. This keeps the security-scoped access open until the next pick.
///
/// Sharing: PhotoBridge accepts any file type (CFBundleDocumentTypes), so
/// it shows in the share sheet. Shared files are copied to tmp and handed to
/// Dart on request (`takeShared`), so none are lost while Flutter starts.
final class FilesBridge: NSObject, UIDocumentPickerDelegate, FlutterSceneLifeCycleDelegate {
  private var channel: FlutterMethodChannel?
  private var pending: FlutterResult?
  private var current: URL?
  private var shared: [String] = []

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "photobridge/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "pickFolder":
        self.present(result)
      case "takeShared":
        result(self.shared + self.collectInbox())
        self.shared = []
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  // MARK: Sharing

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let contexts = connectionOptions?.urlContexts { receive(contexts.map(\.url)) }
    return false
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    receive(URLContexts.map(\.url))
    return true
  }

  private func receive(_ urls: [URL]) {
    let copied = urls.filter(\.isFileURL).compactMap(Self.copyToTemp)
    guard !copied.isEmpty else { return }
    shared += copied
    channel?.invokeMethod("sharedAvailable", arguments: nil)
  }

  /// Files iOS dropped into Documents/Inbox (when it copies rather than
  /// opening in place), e.g. from a share made while the app was closed.
  private func collectInbox() -> [String] {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return [] }
    let inbox = docs.appendingPathComponent("Inbox")
    let items = (try? FileManager.default.contentsOfDirectory(
      at: inbox, includingPropertiesForKeys: nil)) ?? []
    let copied = items.compactMap(Self.copyToTemp)
    try? FileManager.default.removeItem(at: inbox)
    return copied
  }

  private static func copyToTemp(_ url: URL) -> String? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared/\(UUID().uuidString)", isDirectory: true)
    let dest = dir.appendingPathComponent(url.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: dest)
    } catch {
      return nil
    }
    // Inbox copies would otherwise show up in Files › PhotoBridge.
    if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
    return dest.path
  }

  // MARK: Folder picker

  private func present(_ result: @escaping FlutterResult) {
    guard pending == nil, let top = Self.topViewController() else { return result(nil) }
    pending = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    current?.stopAccessingSecurityScopedResource()
    current = nil
    guard let url = urls.first else { return finish(nil) }
    // False for folders inside our own sandbox, which need no extra access.
    if url.startAccessingSecurityScopedResource() { current = url }
    finish(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  private func finish(_ path: String?) {
    pending?(path)
    pending = nil
  }

  private static func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    var vc = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
