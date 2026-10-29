import Foundation

/// Decimal storage units match macOS file sizes. Scaling never narrows UInt64 to Int64 or Double.
@MainActor final class NativeNumberFormat {
  static let system = NativeNumberFormat(locale: .autoupdatingCurrent)
  private let amount = NumberFormatter()
  private let integer = NumberFormatter()
  private let units: [String]
  private let oneByte: String
  private let durationStyle: Duration.UnitsFormatStyle

  init(locale: Locale) {
    durationStyle = Duration.UnitsFormatStyle(
      allowedUnits: [.hours, .minutes, .seconds], width: .abbreviated
    ).locale(locale)
    for formatter in [amount, integer] {
      formatter.locale = locale
      formatter.numberStyle = .decimal
      formatter.usesGroupingSeparator = true
      formatter.minimumFractionDigits = 0
    }
    amount.maximumFractionDigits = 1
    integer.maximumFractionDigits = 0
    let names = ByteCountFormatter()
    names.countStyle = .file
    names.includesCount = false
    names.allowsNonnumericFormatting = false
    names.allowedUnits = .useBytes
    oneByte = names.string(fromByteCount: 1)
    units = [ByteCountFormatter.Units.useBytes, .useKB, .useMB, .useGB, .useTB, .usePB, .useEB]
      .map { unit in
        names.allowedUnits = unit
        return names.string(fromByteCount: 2)
      }
  }

  func storage(_ bytes: UInt64) -> String {
    var unit = 0
    var remaining = bytes
    while remaining >= 1000 && unit < units.count - 1 {
      remaining /= 1000
      unit += 1
    }
    let scaled = NSDecimalNumber(mantissa: bytes, exponent: Int16(-3 * unit), isNegative: false)
    return amount.string(from: scaled)! + " " + (bytes == 1 ? oneByte : units[unit])
  }

  func count(_ value: UInt64) -> String {
    integer.string(from: NSDecimalNumber(mantissa: value, exponent: 0, isNegative: false))!
  }

  /// "1 item", "0 items", "2 items": the count with the singular or plural noun.
  func count(_ value: UInt64, one: String, other: String) -> String {
    "\(count(value)) \(value == 1 ? one : other)"
  }

  /// A duration in the locale's abbreviated units: "8 sec", "1 min, 5 sec", "1 hr, 2 min, 5 sec".
  func duration(_ value: Duration) -> String { value.formatted(durationStyle) }
}
