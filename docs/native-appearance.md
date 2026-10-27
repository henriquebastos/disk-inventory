# Native appearance and color owners

The [native explorer](native-explorer.md) follows the system appearance: light, dark and
Increase Contrast. Swift code has no hex colors, and the user accent stays the system accent.
The map image is the only place where Rust chooses colors. This page names the owner of each
color and the tests that check it.

## Color owners

| Element | Owner | Light and dark | Increase Contrast |
|---|---|---|---|
| File tile base colors and gradient | Rust `type_color`, `gradient_color` in [diagram.rs](../src/diagram.rs) | Same | Same |
| Top and left file seam | Rust `MapAppearance::seam_factor` | Gradient value × 0.775 | Gradient value × 0.33 |
| Aggregate hatch | Rust `MapAppearance::hatch` (sRGB) | Light `[206,206,210]` and `[184,184,189]`, dark `[59,59,62]` and `[38,38,40]` | Light `[232,232,236]` and `[150,150,156]`, dark `[96,96,100]` and `[28,28,30]` |
| Tree swatch of a file | Rust base color through `OutlineRow.map_rgb` | Same | Same |
| Tree swatch of a directory | Swift `NSColor.systemGray` | System | System |
| Map surround, motion hole | Swift `windowBackgroundColor` | System | System |
| Dim, selection ring | Swift, black and white | Same | Same |
| Hover outline | Swift, white | 1 point, 70% opacity | 2 points, opaque |
| Tree background | AppKit `.inset` table style | Opaque content color | System |
| Header and card | SwiftUI `.bar` material | System | System |
| Text | SwiftUI primary label color | System | System |

The palette, the gradient, the geometry and the pixel owners do not change with the
appearance. Increase Contrast seam contrast is measured against its own tile: each seam pixel
against the next interior pixel of the same tile, at every gradient position. The minimum is
3.02:1. A seam next to a different tile is not a contrast criterion. The light-contrast hatch
stripes measure 2.41:1, the dark-contrast stripes 2.71:1.

Text uses the primary label color. The secondary label color measures 3.95:1 on the light
window, below the 4.5:1 text minimum, so font size and weight carry the hierarchy.

## Appearance changes

`DiagramPicture` asks Rust for a frame in one `MapAppearance` and tags the image with the
sRGB color space. `MapAppearance(NSAppearance, increaseContrast:)` uses `bestMatch(from:)`
over the aqua, dark aqua and both high-contrast names. Real Increase Contrast can keep the
plain names, so `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` also selects a
contrast variant.

`MapView` reports its appearance when it moves to a window, from
`viewDidChangeEffectiveAppearance`, and on
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
`ExplorerModel.mapAppearanceChanged` stores a changed value and uses the 180 ms resize
debounce. The rebuild reuses the session, the tree query and the row slice. It makes a new
map from saved data only: no scan and no live metadata. A recovery rebuild repeats until both
the viewport and the appearance are stable.

In fixture mode only, `DI_APPEARANCE` (`light`, `dark`, `light-contrast`, `dark-contrast`)
sets `NSApp.appearance` and fixes the map variant. Production ignores the variable. AppKit
cannot make a high-contrast `NSAppearance`, so a contrast value changes the map and the hover
outline, not the system chrome. The fixture-only `map-appearance` accessibility probe names the
appearance of the displayed map picture.

## Executable evidence

Rust, in [src/explorer_tests.rs](../src/explorer_tests.rs):
"diagram_appearance_changes_only_hatch_and_seam_colors" renders every palette type, nested
aggregates and long thin tiles in all four variants. Owners, hits and interiors match. Hatch
pixels are exact. Seams scale by the variant factor. The test prints the Increase Contrast seam
minimum and requires 3.0:1. In [src/bridge/tests.rs](../src/bridge/tests.rs),
"diagram_appearance_is_forwarded_and_swatch_colors_are_unchanged" checks the generated
`diagram` parameter, the hatch, unchanged interiors and unchanged `map_rgb` values.

Model tests in
[AppearanceModelTests.swift](../native/ExplorerModelTests/AppearanceModelTests.swift):

- "testDiagramPictureIsSRGBAndCarriesAppearance".
- "testMapAppearanceMapsSystemAppearanceNames".
- "testFixtureAppearanceOverrideIsIgnoredOutsideFixtureMode".
- "testAppearanceChangeRebuildsOnlyTheMapFromSavedData": an offscreen `MapView` appearance
  change gives one rebuild in under 900 ms with the one-second live-metadata fixture. The
  session, tree query, rows and selection stay.
- "testTreeUsesInsetContentStyleAndAdaptiveDirectorySwatch".

UI tests in [ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift) read the
real runner's screenshots:

- "testAppearanceVariantsRenderMapChromeAndSheets": the probe for each value, with overview,
  selection, hover and both alert sheets.
- "testMapHatchFollowsAppearance": light stripes on a light window, dark stripes on a dark
  window, stronger stripes with a contrast value.
- "testIncreasedContrastDarkensMapSeams": at least 3:1 with a contrast value, below 2:1 without.
- "testIncreasedContrastHoverStrokeIsOpaqueAndTwoPointsWide".
- "testTreeUsesOpaqueContentBackgroundAndSystemGrayDirectorySwatch".
- "testMapTileBaseColorMatchesTreeSwatchOnScreen": the sRGB map shows the swatch color exactly.
- "testCaptionAndSecondaryTextMeetFourAndAHalfToOne": card, footer and start-screen text.
- "testTreeSizeTextCentersWithNameOnSelectedAndUnselectedRows" runs in all four values.

Untested: the system chrome under real Increase Contrast, and a live system appearance change
in a UI test. Both need a system setting change, which tests must not make.
