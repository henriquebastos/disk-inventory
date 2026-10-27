import AppKit

// CGImage and the generated frame are immutable; construction happens off-main.
struct DiagramPicture: @unchecked Sendable {
  let frame: DiagramFrame
  let bitmap: BitmapRecord
  let image: CGImage
  let targets: [DiagramSelection]
  /// The appearance whose hatch and seam colors Rust drew into `image`.
  let appearance: MapAppearance
  /// Rust writes sRGB bytes, so the image carries the sRGB profile for color management.
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  init(session: ExplorerSession, focus: EntryKey, size: CGSize, appearance: MapAppearance) throws {
    let frame = try session.diagram(
      focus: focus, width: UInt32(size.width), height: UInt32(size.height),
      appearance: appearance)
    let bitmap = frame.bitmap()
    guard let provider = CGDataProvider(data: bitmap.rgba as CFData),
      let image = CGImage(
        width: Int(bitmap.width), height: Int(bitmap.height), bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: Int(bitmap.width) * 4, space: Self.colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw CocoaError(.coderInvalidValue) }
    self.frame = frame
    self.bitmap = bitmap
    self.image = image
    self.appearance = appearance
    targets = try frame.targets()
  }
}

extension MapAppearance {
  /// The map variant for a system appearance. Real Increase Contrast can keep the plain
  /// appearance names, so `increaseContrast` also selects a contrast variant.
  init(_ appearance: NSAppearance, increaseContrast: Bool = false) {
    switch appearance.bestMatch(from: [
      .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]) {
    case .accessibilityHighContrastDarkAqua: self = .darkIncreasedContrast
    case .accessibilityHighContrastAqua: self = .lightIncreasedContrast
    case .darkAqua: self = increaseContrast ? .darkIncreasedContrast : .dark
    default: self = increaseContrast ? .lightIncreasedContrast : .light
    }
  }
  init?(fixtureName: String) {
    switch fixtureName {
    case "light": self = .light
    case "dark": self = .dark
    case "light-contrast": self = .lightIncreasedContrast
    case "dark-contrast": self = .darkIncreasedContrast
    default: return nil
    }
  }
  /// Fixture `DI_APPEARANCE` value and `map-appearance` probe label.
  var fixtureName: String {
    switch self {
    case .light: "light"
    case .dark: "dark"
    case .lightIncreasedContrast: "light-contrast"
    case .darkIncreasedContrast: "dark-contrast"
    }
  }
  var increasedContrast: Bool { self == .lightIncreasedContrast || self == .darkIncreasedContrast }
  var dark: Bool { self == .dark || self == .darkIncreasedContrast }
}
