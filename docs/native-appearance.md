# Native appearance and color owners

The [native explorer](native-explorer.md) follows the system appearance: light, dark and
Increase Contrast. Swift code has no hex colors, and the user accent stays the system accent.
The map image is the only place where Rust chooses colors. This page names the owner of each
color and the tests that check it.

## Color owners

| Element | Owner | Light and dark | Increase Contrast |
|---|---|---|---|
| File tile base colors and gradient | Rust `FolderContext::file_color` in [file_type.rs](../src/file_type.rs), `gradient_color` in [diagram.rs](../src/diagram.rs) | Same | Same |
| Tile seam, all four edges | Rust `MapAppearance::seam_factor` | Value × 0.55 (design inset) | Value × 0.33 |
| Root Trash fill | Rust `MapAppearance::trash` (design TRASH) | Dark base `[68,72,78]`, white 9% stripes; light base `[185,190,198]`, black 9% stripes | Dark base `[132,136,142]`, white 30% stripes; light as light, black 30% stripes |
| Aggregate hatch | Rust `MapAppearance::hatch` (sRGB) | Light `[206,206,210]` and `[184,184,189]`, dark `[59,59,62]` and `[38,38,40]` | Light `[232,232,236]` and `[150,150,156]`, dark `[96,96,100]` and `[28,28,30]` |
| Tree swatch of a file | Rust base color through `OutlineRow.map_rgb` | Same | Same |
| Tree swatch of a directory | Swift `NSColor.systemGray` | System | System |
| Map surround, motion hole | Swift `windowBackgroundColor` | System | System |
| Dim (12% black), selection ring | Swift, black and white | Same | Same |
| Hover outline | Swift | White, 1 point, 70% opacity | 2 points, opaque: label color (black) in light, white in dark |
| Tree background | AppKit `.inset` table style | Opaque content color | System |
| Header and card | SwiftUI `.bar` material | System | System |
| Text | SwiftUI primary label color | System | System |

The palette, the gradient, the geometry and the pixel owners do not change with the
appearance. Increase Contrast seam contrast is measured against its own tile: each seam pixel
against the next interior pixel of the same tile, at every gradient position. The minimum is
3.02:1 in Rust and 3.23:1 on screen. A seam next to a different tile is not a contrast
criterion. The light-contrast hatch stripes measure 2.41:1, the dark-contrast stripes 2.71:1.

The Trash seam darkens the darker stripe band, so it has no stripes. No dark seam reaches 3:1
against the design's dark Trash base (black caps at 2.16:1), so dark Increase Contrast uses a
lighter base. Its seam measures at least 4.03:1, the light-contrast Trash seam 3.78:1. Trash
stripe against base: light 1.20:1, dark 1.29:1, light contrast 1.95:1, dark contrast 1.58:1.
Black stripes on the lighter dark-contrast base would give 1.80:1 but a 2.26:1 seam.

Dark `prototype-home` against the design render 1a-browse.png, with the screenshot converted
to sRGB: tile interiors per kind differ by at most 0.6 levels per channel, before and after the
four-edge seam. The whole map measured 96.2, 137.9, 128.6 with the top/left seam at × 0.775 and
measures 94.7, 135.4, 126.0 now; the render is 95.0, 136.1, 126.4. The tolerance is 1.5 levels
per channel, because the render is 1x with smoothed seams and our map is 2x and 9% smaller.

Text uses the primary label color. The secondary label color measures 3.95:1 on the light
window, below the 4.5:1 text minimum, so font size and weight carry the hierarchy.

## File type colors

[file_type.rs](../src/file_type.rs) owns the kinds and the rule. The palette is the
prototype's: blue video, green images, pink audio, gold archives, purple apps, cyan code, orange
caches, olive data, and one muted gray for documents and unknown files. A fixed table maps
240 common extensions to these kinds; there is no new kind, because documents already have the
prototype's muted kind and every other common extension fits a colored kind. The extension is
the bytes after the last `.` within the last 12 basename bytes, ASCII case-insensitive, so it has
at most 11 bytes (`swiftmodule`, `sparseimage`, `sqlite-wal`). Numeric extensions are not listed.

The folder rule colors a file whose extension is missing, unknown or numeric by its nearest
context folder; a known extension keeps its own color, gray documents included. Names are exact,
case-sensitive byte matches, and a context covers every descendant:

- Archive: `objects` whose parent is `lfs`, a Git directory (`.git` or a bare repository
  `<name>.git`), or any folder below `modules` inside a Git directory (Git object storage).
  Git names a submodule after its path, so `.git/modules/vendor/lib/objects` and nested
  submodules count. `modules/objects` (a submodule named `objects`) and `modules/<name>/objects`
  outside a Git directory stay gray. Known false positive: an `objects` folder that is part of a
  submodule name (`modules/lib/objects/x`) or of a submodule's refs is archive, with its files.
- Cache: `Caches`, `Cache`, `.cache`, `_cacache` and `.pnpm-store`; `store` whose parent is
  `pnpm`; `blobs` whose parent starts with `models--` or `datasets--`, or that has a
  `huggingface` ancestor. Lowercase `cache` stays gray.

Layout computes a directory's context once, from its name and its parent's context, when it
reaches the directory. A focus starts from bounded walks over its saved ancestors and the saved
root path, so a focus inside a context folder keeps the color. Tree swatches use the same rule. No
lookup allocates or reads metadata.

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

Rust, in [src/file_type/tests.rs](../src/file_type/tests.rs):
"extension_table_is_sorted_lowercase_and_fits_the_name_tail",
"known_extensions_map_to_each_kind_case_insensitively_within_the_name_tail",
"folder_rule_colors_files_without_a_known_extension_by_context" (with look-alike folders that
stay gray) and "focus_context_from_saved_ancestors_and_root_path_equals_entering_from_the_root".
In [src/explorer_tests.rs](../src/explorer_tests.rs),
"diagram_colors_files_by_extension_and_folder_context_also_inside_a_focused_context" reads the
drawn pixels. In [src/bridge/tests.rs](../src/bridge/tests.rs),
"file_type_colors_fixture_colors_new_extensions_and_context_folders_in_map_and_tree" checks
map tiles and tree swatches of the `file-type-colors` fixture.

Rust, in [src/explorer_tests.rs](../src/explorer_tests.rs):
"diagram_appearance_changes_only_hatch_and_seam_colors" renders every palette type, nested
aggregates and long thin tiles in all four variants. Owners, hits and interiors match. Hatch
pixels are exact. Seams on all four edges scale by the variant factor. The test prints the
Increase Contrast seam minimum and requires 3.0:1.
"diagram_paints_every_trash_whole_with_trash_stripes_until_focused" checks the Trash fill, its
seams and its stripe contrast in all four variants. In [src/bridge/tests.rs](../src/bridge/tests.rs),
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

Rust pixel tests in [map_pixels.rs](../src/bridge/tests/map_pixels.rs) measure the bitmap at the
size of the map in the default window, in all four values unless noted:

- "presentation_hatch_follows_appearance_and_increase_contrast_strengthens_its_stripes": light
  stripes on a light window, dark stripes on a dark window, stronger with a contrast value.
- "presentation_large_file_seam_is_the_design_inset_and_darker_with_increase_contrast": at least
  3:1 with a contrast value, 1.8 to 3:1 without.
- "prototype_home_tiles_have_the_design_seam_on_all_four_sides": each edge of the largest tiles.
- "prototype_home_root_trash_is_one_striped_region_until_focused" and
  "prototype_home_nested_trash_is_striped_at_its_parent_level_until_focused": visible TRASH
  stripes in one region; focused, no `.Trash` pixel and over 30% video colors.
- "prototype_home_map_shows_every_kind_color_and_presentation_stays_gray" (light and dark).
- "file_type_colors_fixture_keeps_type_colors_in_light_and_dark_and_inside_object_folders": each
  tile has its kind's hue and the controls stay gray, also with the focus on `.git/objects`, a
  nested or slash-named submodule's `objects` or a bare repository's `objects`.

[MapDrawingModelTests.swift](../native/ExplorerModelTests/MapDrawingModelTests.swift) draws the
map view offscreen at 2x: "testHoverStrokeFollowsAppearanceAndIsOpaqueTwoPointsWithIncreasedContrast"
(black in light contrast, white in dark contrast, 70% white without) and
"testSelectionDimIsLightAndKeepsUnselectedSeamsVisible" (in [native-status.md](native-status.md)).

UI tests in [ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift) read the
real runner's screenshots:

- "testAppearanceVariantsRenderMapChromeAndSheets": the probe for each value, with overview,
  selection, hover and both alert sheets.
- "testPrototypeHomeDarkMapMatchesTheDesignBrightness": CSS-gradient interiors and a 0.55 edge
  ratio, which shows that the window draws the bitmap 1:1.
- "testTreeUsesOpaqueContentBackgroundAndSystemGrayDirectorySwatch" runs in all four values.
- "testMapTileBaseColorMatchesTreeSwatchOnScreen": the sRGB map shows the swatch color exactly.
- "testCaptionAndSecondaryTextMeetFourAndAHalfToOne": card count, path and grouped size,
  status bar and start-screen text.
- "testTreeSizeTextCentersWithNameOnSelectedAndUnselectedRows" runs in all four values.

Untested: the system chrome under real Increase Contrast, and a live system appearance change
in a UI test. Both need a system setting change, which tests must not make.
