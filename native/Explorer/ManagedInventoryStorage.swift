import Foundation

struct ManagedInventory: Codable, Sendable {
  let filename: String
  let scannedAt: Date
  /// The scanned root as lossy display text. Older metadata may lack it. It is a label only:
  /// reopening uses `filename`, which must name an owned generation.
  let rootName: String?

  /// "Reopen “NAME”" with the root's last path component, as in the root breadcrumb.
  var reopenTitle: String {
    guard let rootName, !rootName.isEmpty else { return "Reopen Last Folder" }
    let name = rootName.split(separator: "/").last.map(String.init) ?? rootName
    return "Reopen “\(middleTruncated(name))”"
  }
}

// Only this app's UUID generations are eligible for retention cleanup.
final class ManagedInventoryStorage: @unchecked Sendable {
  let root: URL
  private let fileManager: FileManager
  init(root: URL, fileManager: FileManager = .default) {
    self.root = root
    self.fileManager = fileManager
  }
  static func applicationSupport(fileManager: FileManager = .default) throws
    -> ManagedInventoryStorage
  {
    let support = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    return ManagedInventoryStorage(
      root: support.appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "org.diskinventory.explorer"),
      fileManager: fileManager)
  }
  private var metadataURL: URL { root.appendingPathComponent("last-inventory.json") }
  private func owned(_ filename: String) -> Bool {
    guard filename.hasPrefix("inventory-"), filename.hasSuffix(".dmap") else { return false }
    return UUID(uuidString: String(filename.dropFirst(10).dropLast(5))) != nil
  }
  func lastInventory() throws -> ManagedInventory? {
    guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
    let record = try JSONDecoder().decode(
      ManagedInventory.self, from: Data(contentsOf: metadataURL))
    guard owned(record.filename) else { throw CocoaError(.fileReadCorruptFile) }
    return record
  }
  func url(for record: ManagedInventory) -> URL { root.appendingPathComponent(record.filename) }
  func newGeneration() throws -> URL {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("inventory-\(UUID().uuidString).dmap")
  }
  func publish(_ generation: URL, scannedAt: Date, rootName: String) throws -> ManagedInventory {
    guard generation.deletingLastPathComponent().path == root.path,
      owned(generation.lastPathComponent)
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let old = try lastInventory()
    let record = ManagedInventory(
      filename: generation.lastPathComponent, scannedAt: scannedAt, rootName: rootName)
    // Atomic metadata replacement is the app retention boundary; the core has already reopened
    // and validated this new snapshot. Never remove the old generation before this succeeds.
    try JSONEncoder().encode(record).write(to: metadataURL, options: .atomic)
    if let old, old.filename != record.filename { try? discard(url(for: old)) }
    return record
  }
  func discard(_ generation: URL) throws {
    guard generation.deletingLastPathComponent().path == root.path,
      owned(generation.lastPathComponent)
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
    // Never remove the generation referenced by the last valid metadata.
    guard try lastInventory()?.filename != generation.lastPathComponent else { return }
    if fileManager.fileExists(atPath: generation.path) {
      try fileManager.removeItem(at: generation)
    }
  }
}
