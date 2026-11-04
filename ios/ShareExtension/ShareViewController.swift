import UIKit
import UniformTypeIdentifiers

/// "Share → PhotoBridge" from Photos (and any other app): choose devices,
/// then the photos and files wait in the shared outbox until PhotoBridge
/// sends them — at once if it's running, otherwise the next time it opens.
final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private struct Device: Decodable {
    let id: String
    let name: String
    let os: String
    let connected: Bool
  }

  private var devices: [Device] = []
  private var chosen = Set<String>()
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let footer = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    title = "PhotoBridge"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Send", style: .done, target: self, action: #selector(send))

    if let file = SharedBox.devicesFile, let data = try? Data(contentsOf: file) {
      devices = (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }
    // Connected devices start ticked.
    chosen = Set(devices.filter(\.connected).map(\.id))
    if chosen.isEmpty { chosen = Set(devices.map(\.id)) }

    table.dataSource = self
    table.delegate = self
    table.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    footer.numberOfLines = 0
    footer.font = .preferredFont(forTextStyle: .footnote)
    footer.textColor = .secondaryLabel
    footer.text = SharedBox.container == nil
      ? "Open PhotoBridge once, then share again."
      : devices.isEmpty
        ? "No paired devices yet. Pair one in PhotoBridge first."
        : "Sent as files (not synced). They go out when PhotoBridge is running, or next time you open it."
    updateSend()
  }

  // MARK: Table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { devices.count }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    "Send to"
  }

  func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    let wrap = UIView()
    footer.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(footer)
    NSLayoutConstraint.activate([
      footer.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
      footer.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8),
      footer.leadingAnchor.constraint(equalTo: wrap.layoutMarginsGuide.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: wrap.layoutMarginsGuide.trailingAnchor),
    ])
    return wrap
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let d = devices[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    var content = cell.defaultContentConfiguration()
    content.text = d.name
    content.secondaryText = d.connected ? "Connected" : "Not connected now: sends when it is"
    content.image = UIImage(systemName: d.os == "macos" ? "laptopcomputer" : "iphone")
    cell.contentConfiguration = content
    cell.accessoryType = chosen.contains(d.id) ? .checkmark : .none
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let id = devices[indexPath.row].id
    if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    tableView.reloadRows(at: [indexPath], with: .none)
    updateSend()
  }

  private func updateSend() {
    navigationItem.rightBarButtonItem?.isEnabled = !chosen.isEmpty && SharedBox.outbox != nil
  }

  // MARK: Sending

  @objc private func cancel() {
    extensionContext?.cancelRequest(withError: NSError(domain: "PhotoBridge", code: 0))
  }

  @objc private func send() {
    guard let outbox = SharedBox.outbox else { return }
    navigationItem.rightBarButtonItem?.isEnabled = false
    footer.text = "Preparing…"
    let job = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let targets = Array(chosen)
    Task {
      do {
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let names = try await copyAttachments(into: job)
        let manifest: [String: Any] = ["to": targets, "files": names]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        // Written last: the app only picks up jobs with a manifest.
        try data.write(to: job.appendingPathComponent("job.json"), options: .atomic)
        CFNotificationCenterPostNotification(
          CFNotificationCenterGetDarwinNotifyCenter(),
          CFNotificationName(SharedBox.outboxNotification as CFString), nil, nil, true)
        extensionContext?.completeRequest(returningItems: nil)
      } catch {
        try? FileManager.default.removeItem(at: job)
        footer.text = "Couldn't prepare the files: \(error.localizedDescription)"
        navigationItem.rightBarButtonItem?.isEnabled = true
      }
    }
  }

  /// Copies every shared photo, video or file into [folder] (the system's
  /// copies disappear when the extension finishes). Returns the file names.
  private func copyAttachments(into folder: URL) async throws -> [String] {
    var names: [String] = []
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    for (i, provider) in providers.enumerated() {
      // Originals first: a movie, then the photo, then any file.
      guard let type = [UTType.movie, .image, .item].first(where: {
        provider.hasItemConformingToTypeIdentifier($0.identifier)
      }) else { continue }
      let name = try await copy(provider, type: type, into: folder, index: i, taken: Set(names))
      names.append(name)
    }
    if names.isEmpty { throw NSError(domain: "PhotoBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nothing to send"]) }
    return names
  }

  private func copy(
    _ provider: NSItemProvider, type: UTType, into folder: URL, index: Int, taken: Set<String>
  ) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
        guard let url else {
          return cont.resume(throwing: error ?? NSError(domain: "PhotoBridge", code: 2))
        }
        var name = provider.suggestedName.map { base -> String in
          let ext = url.pathExtension
          return ext.isEmpty || base.lowercased().hasSuffix(".\(ext.lowercased())") ? base : "\(base).\(ext)"
        } ?? url.lastPathComponent
        if name.isEmpty { name = "item\(index)" }
        // Two shared items with the same name: keep both.
        if taken.contains(name) { name = "\(index)-\(name)" }
        do {
          try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
          cont.resume(returning: name)
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }
}
