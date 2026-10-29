import AppKit
import XCTest

@testable import DiskInventory

@MainActor final class NativeNumberFormatTests: XCTestCase {
  func testDecimalStorageUsesLocaleAndPreservesUnsignedRange() {
    for (locale, decimal, grouped) in [
      ("en_US", ".", "18,446,744,073,709,551,615"),
      ("pt_BR", ",", "18.446.744.073.709.551.615"),
    ] {
      let format = NativeNumberFormat(locale: Locale(identifier: locale))
      XCTAssertEqual(format.storage(0), "0 bytes")
      XCTAssertEqual(format.storage(1), "1 byte")
      XCTAssertEqual(format.storage(999), "999 bytes")
      XCTAssertEqual(format.storage(1000), "1 KB")
      XCTAssertEqual(format.storage(1536), "1\(decimal)5 KB")
      XCTAssertEqual(format.storage(1_500_000), "1\(decimal)5 MB")
      XCTAssertEqual(format.storage(1_500_000_000), "1\(decimal)5 GB")
      XCTAssertEqual(format.storage(.max), "18\(decimal)4 EB")
      XCTAssertEqual(format.count(.max), grouped)
      XCTAssertEqual(format.count(0), "0")
      XCTAssertEqual(format.count(12345), locale == "en_US" ? "12,345" : "12.345")
    }
  }

  func testCountUsesTheSingularNounOnlyForOne() {
    let format = NativeNumberFormat(locale: Locale(identifier: "en_US"))
    XCTAssertEqual(format.count(0, one: "scan error", other: "scan errors"), "0 scan errors")
    XCTAssertEqual(format.count(1, one: "scan error", other: "scan errors"), "1 scan error")
    XCTAssertEqual(format.count(2, one: "scan error", other: "scan errors"), "2 scan errors")
    XCTAssertEqual(format.count(1234, one: "item", other: "items"), "1,234 items")
  }

  func testStorageUnitNamesMatchNativeHostFormatter() {
    // The numeric locale is injectable. Unit language follows the host's native formatter.
    let native = ByteCountFormatter()
    native.countStyle = .file
    native.includesCount = false
    native.allowsNonnumericFormatting = false
    for locale in ["en_US", "fr_FR"] {
      let format = NativeNumberFormat(locale: Locale(identifier: locale))
      for (bytes, unit, number): (UInt64, ByteCountFormatter.Units, String) in [
        (0, .useBytes, "0"), (1, .useBytes, "1"), (2, .useBytes, "2"),
        (1500, .useKB, locale == "en_US" ? "1.5" : "1,5"),
        (.max, .useEB, locale == "en_US" ? "18.4" : "18,4"),
      ] {
        native.allowedUnits = unit
        let name = native.string(fromByteCount: bytes == 1 ? 1 : 2)
        XCTAssertEqual(format.storage(bytes), number + " " + name)
      }
    }
  }

  func testVisibleTreeSizeUsesInjectedLocaleWithoutChangingAccounting() async throws {
    for (locale, text) in [("en_US", "4.1 KB"), ("pt_BR", "4,1 KB")] {
      let model = ExplorerModel(
        arguments: ["--fixture-mode", "--scenario", "presentation"], environment: [:],
        numbers: NativeNumberFormat(locale: Locale(identifier: locale)))
      try await waitUntil { !model.loading && model.outline != nil }
      defer { model.shutdown() }
      let row = try XCTUnwrap(
        model.outline?.rows.firstIndex { $0.entry.displayName == "large-file" })
      XCTAssertEqual(model.outline!.rows[row].entry.subtreeBytes, 4096)
      let coordinator = ContentsTree.Coordinator(model)
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
      let cell = try XCTUnwrap(
        coordinator.tableView(NSTableView(), viewFor: column, row: row)
          as? ContentsTree.SizeCell)
      XCTAssertEqual(cell.label.stringValue, text)
      XCTAssertEqual(cell.label.toolTip, text)
    }
  }
}
