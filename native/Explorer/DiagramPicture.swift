import AppKit

// CGImage and the generated frame are immutable; construction happens off-main.
struct DiagramPicture: @unchecked Sendable {
  let frame: DiagramFrame
  let bitmap: BitmapRecord
  let image: CGImage
  let targets: [DiagramSelection]
  init(session: ExplorerSession, focus: EntryKey, size: CGSize) throws {
    let frame = try session.diagram(
      focus: focus, width: UInt32(size.width), height: UInt32(size.height))
    let bitmap = frame.bitmap()
    guard let provider = CGDataProvider(data: bitmap.rgba as CFData),
      let image = CGImage(
        width: Int(bitmap.width), height: Int(bitmap.height), bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: Int(bitmap.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw CocoaError(.coderInvalidValue) }
    self.frame = frame
    self.bitmap = bitmap
    self.image = image
    targets = try frame.targets()
  }
}
