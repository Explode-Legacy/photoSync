import BackgroundTasks
import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let continued = ContinuedSync()

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
