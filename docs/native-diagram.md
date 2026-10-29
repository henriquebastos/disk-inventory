# Native diagram and virtual tree

The [native explorer](native-explorer.md) uses generated objects in
[src/bridge/views.rs](../src/bridge/views.rs). Rust owns saved inventory, accounting,
geometry and rasterization. Swift owns input, native controls, asynchronous coordination
and presentation. These views never authorize removal; only the prepared action of
[bridge.md](bridge.md) does.

## Placement and pixel authority

[src/layout.rs](../src/layout.rs) supplies the residual-orientation squarify used by
both the diagram and legacy `Explorer.layout`. Bounded siblings (including any
rollup) sort by descending integer weight; a row grows while adding its next item
improves or preserves the worst aspect ratio. Rows span the residual rectangle's
short side, then orientation is recomputed for the remainder. Integer sums and
remaining-weight ratios preserve exact byte accounting even above floating-point
integer precision; only geometry uses floating point. Unrepresentable subdivisions
retain their parent. Native raster geometry uses cumulative integer-weight endpoints
and final-edge closure to prevent drift across large sibling prefixes at nonzero
origins.

The placement equals the design prototype's `layout()`: the same rows, worst-ratio test,
orientation, largest-first order and no padding.
"squarify_matches_prototype_layout_at_render_and_portrait_viewports" in
[prototype_parity_tests.rs](../src/bridge/fixture/prototype_parity_tests.rs) ports its `sq()`
and `place()` and lays out the `prototype-home` fixture. At 939×750 (the design render),
640×900 and 1702×1443 (the app map), all 503 compared files match within 1 px. Not compared:
files that the prototype omits (hatched directories under 3 px, files under 0.5 px²) and files
inside our aggregates or the `.Trash` region (11 files). A rollup is one sibling with the
summed weight, so at 200×150 and 60×40 later siblings can move.

Both views use the same priority-driven bounded refinement machinery, preserving
zero-area semantics. Directory accounting and unresolved descendants remain aggregates.

[src/diagram.rs](../src/diagram.rs) accepts 1–4,000,000 backing pixels, at most
`min(pixels, 1,000,000)` combined tile/group regions and twice that many child-ID
visits, including rejected work. Refinement uses projected pixel area, not a byte
cutoff or fixed nesting depth. A positive geometric area need not contain a pixel
center; zoom can expose detail absent at overview scale. Zero-attribution entries
remain in the tree, with no artificial map area.

Each actually covered pixel has one owner. A high owner bit marks aggregate pixels
non-actionable. Hit lookup is O(1), followed by saved-record/path construction;
selection-region lookup scans bounded frame regions. Geometry, not a header overlay,
owns file pixels. File colors come from saved names only: the extension table and the
folder rule in [native-appearance.md](native-appearance.md). A 155-degree linear gradient runs
from 14% white through the base at 55% to 16% black, independent of ancestor depth.
Each file tile has a one-backing-pixel seam on all four edges, the design's 0.5-point inset
at 45% black. Gray diagonal hatching marks non-actionable aggregates. Each directory named exactly `.Trash`
(a byte match) below the focus is one actionable tile with the design's TRASH stripes, at any
depth. Its children are never read, so it selects that `.Trash`. A focus on or inside a
`.Trash` draws its files normally.
`diagram` takes a `MapAppearance`, which changes only the hatch, the Trash fill and the seam
strength ([native-appearance.md](native-appearance.md)). Swift tags the bitmap as
sRGB. Selection dimming and hover outlines remain native overlays,
not baked into the bitmap or owner buffer.

`DiagramFrame.bitmap` transfers one flat RGBA buffer plus counts/timing/payload
statistics. `hit` transfers one owner; `region` one rectangle. `targets` supplies at
most 24 sufficiently large file or Trash targets for drawing accessibility; the virtual
tree is exhaustive. Swift scales the raster with nearest-neighbor
sampling when the pixel envelope binds and maps input back into that raster.

Counts are bounds, not memory or display-time guarantees. Retained vector payload
excludes allocator overhead, layout scratch, FFI copies and native image-provider
memory. `surface_payload_bytes` is always zero. Core RSS and Swift peak are separate. Two frame builds cannot run concurrently in the model;
a displayed old frame may coexist with the next build and transfer copies. Bounded
in-flight hit/region queries can briefly retain an obsolete frame; accessibility
targets hold only weak frame references. Deep-path
construction costs depend on saved ancestry. Worst-case allocator overhead across
all possible hierarchies and compositor latency are unverified.

## Sparse tree and lifecycle

[src/tree_view.rs](../src/tree_view.rs) reuses the inventory's sorted CSR child index.
It stores expanded branches and prefix counts, not a presentation object per child.
Virtual rows address a huge fanout without enumerating its siblings. Transfers contain
1–256 rows with depth/expansion and work/payload counts. Reveal opens saved ancestors
and updates affected expansion prefixes; collapse removes descendant expansion state.
Row visits count addressing branches. Prefix/child-map
payload is maintained on expansion edits; allocator overhead remains excluded. Read-only `visible_row`
(Swift `visibleRow`) ascends expanded ancestors using CSR rank searches and binary
searches over cached prefix counts; it never scans all rows or opens a branch.
Hidden/out-of-focus entries and the implicit root return no row. Disclosure uses
this lookup for the selected key, not its old numeric row, and checks the selection
version before publishing. A collapsed selected descendant stays selected as an
action target but has no tree highlight until explicitly made visible again.
Native row indentation caps
at 120 points without capping semantic depth or inventory access.

[ExplorerModel+Tree.swift](../native/Explorer/ExplorerModel+Tree.swift) keeps one 256-row slice;
one incoming slice can coexist during publication. Resize builds reuse that slice,
not a second row cache. The 64-context per-directory cache stores opaque sparse tree
handles and keys/scroll positions only. This count is not itself a byte limit;
aggregate expansion payload can be queried independently of the shared inventory.
History resolves selected `visibleRow` independently of the restored page, without
revealing hidden ancestors or scrolling to selection. Native restoration aligns the
saved top unobscured row below AppKit's automatic header inset, subject to viewport
clamping; merely making that row visible would lose the previous scroll position. Right-arrow ignores empty
directories and verifies a proposed child's parent. Parent selection has one active
request plus one replaceable pending request, with identity/generation and interactive
state checks before dispatch and publication.

Session/view/selection generations reject obsolete work. Core frames and trees also
capture an inventory revision; execution and an applied refresh invalidate their queries.
A stopped refresh changed nothing, so its old queries stay valid. An immutable old bitmap remains drawable, but obsolete hit/region/
row calls fail. Navigation contexts clear on replacement/recovery; obsolete saved trees
rebuild rather than republishing stale row counts. Preparing actions still performs
fresh metadata/pin checks inside Rust, separate from ordinary presentation.
Rejected execution also rebuilds current presentation without suppressing the error.
A failed constructor rebuilds the retained session before ending read-only replacement.

## Executable invariants

[src/explorer_tests.rs](../src/explorer_tests.rs):

- "diagram_squarify_places_compact_siblings_in_wide_tall_and_retina_frames": short-side
  rows of compact equal files rather than long-side strips; legacy geometry
  agreement within roundoff, proportional areas and complete ownership in wide/tall 1×/2× frames.
- "diagram_skewed_nested_geometry_keeps_area_coverage_zero_and_budget_semantics":
  skewed nested/deep weights, pixel coverage, zero area and bounded visits.
- "rejected_subdivisions_consume_the_global_work_budget": rejected work remains
  bounded in both endpoint modes of the shared refinement implementation.
- "diagram_pixel_detail_and_zoom_preserve_weights_and_hit_authority": detail above
  160 tiles, tiny-file zoom, aggregate non-authority and deterministic raster bytes.
- "diagram_integer_precision_hardlinks_and_zero_entries_survive_squarify": exact
  u64::MAX accounting, hardlink deduplication, zero-area tree access and pixel/work bounds.
- "diagram_flat_gradient_has_no_ancestor_ridges_and_aggregates_are_hatched": identical
  shallow/deep raster bytes, monotonic interior shading, four-edge seams and aggregate authority.
- "diagram_paints_every_trash_whole_with_trash_stripes_until_focused": exact TRASH pixels
  for a root and a nested `.Trash` at two focus levels, unread children, type colors for
  `.trash` and inside a focused `.Trash`. "prototype_home_nested_trash_draws_projects_trash_whole_until_focused"
  in [src/bridge/tests.rs](../src/bridge/tests.rs) checks the same in `prototype-home-nested-trash`.

[src/diagram.rs](../src/diagram.rs):
"type_palette_matches_prototype_and_flat_gradient_is_monotonic".
[src/bridge/tests.rs](../src/bridge/tests.rs)
"outline_swatch_colors_match_map_file_tiles_and_directories_have_none" checks that
tree rows carry the base color of their map file tile and that directories carry none.
[src/diagram/scale_tests.rs](../src/diagram/scale_tests.rs):
"million_file_diagram_respects_pixel_region_work_and_memory_envelopes" records
one-million-file/max-pixel core payload, RSS and timing, excluding FFI/Swift/display.

[src/tree_view/tests.rs](../src/tree_view/tests.rs):
"million_child_expansion_materializes_only_requested_rows",
"deep_reveal_is_iterative_and_outside_keys_do_not_change_expansion", and
"virtual_rows_preserve_size_order_zero_and_shared_entries" cover actual inventory
fanout, 2000-deep ancestry, ordering, zero/shared attribution and sparse transfer.
"visible_row_tracks_sibling_shifts_without_expanding_hidden_ancestors" verifies
unaffected/shifted siblings, hidden descendants, root/scope/foreign-key handling
and unchanged expansion state. Million-child/deep tests also query visible rows.
"row_payload_accounting_does_not_traverse_expansion_state" measures payload-term
reads before/after deep collapse and checks incremental counts against full sums.
[src/bridge/tests.rs](../src/bridge/tests.rs):
"diagram_and_virtual_tree_are_native_free_bounded_and_revision_guarded" checks
large nested-origin sibling prefixes in wide/tall/odd/2× frames, complete raster
coverage, bounded visits, no source access and revision guards.

[native/ExplorerModelTests/DixModelTests.swift](../native/ExplorerModelTests/DixModelTests.swift):

- "testHoverLeavesPreparedSelectionUntouchedAndClickRevealsWithoutZoom".
- "testAggregatePixelExplainsRecordedBytesWithoutCreatingAnActionTarget".
- "testDisclosureZoomBreadcrumbAndAncestorRestoreContext".
- "testDisclosurePreservesUnaffectedMovieSelection".
- "testDisclosureRecomputesMovieRowAfterPrecedingSiblingChanges".
- "testDisclosureHidesSelectedDescendantWithoutReopeningOrRetargeting".
- "testDisclosureResultsRejectNewerSelectionSessionAndMutation": the real delayed
  metadata lock overlaps disclosure with newer selection, replacement and recovery.
- "testHistoryCapPayloadAndSessionAndMutationInvalidation".
- "testHistoryRebuildsAfterExternalRevisionChange".
- "testHistoryRestoresNativeTopRowRatherThanOnlyMakingItVisible": real offscreen
  AppKit clip-view origin and model scroll observation agree after parent navigation.
- "testShortTreeRestoreKeepsFirstRowBelowNativeHeader": a one-row scope's label
  remains below, rather than underneath, the table header after restoring its origin.
- "testAccessibilityTargetsDoNotRetainObsoleteFrames".
- "testStaleHoverRevealAndFrameCannotPublishAcrossSessionReplacement".
- "testNativeHundredThousandRowsAreVirtual": real
  NSTableView cells and tail scrolling.
- "testNativeDatasourceCallbacksUseCachedRowsWhileBridgeIsBusy": cached datasource
  callbacks during an explicit same-session metadata-delay fixture call.
- "testDownsampledPointerMatchesRustOwnerAndAppKitDrawUsesCachedImage": backing
  mapping and cached offscreen AppKit drawing, not display completion.
- "testOffscreenAppKitTrackingKeyboardAndDisclosureCallbacks": actual native
  disclosure, key and tracking callbacks.
- "testUsageBarPercentRoundsHalfUpKeepsSliverAndEmptiesZeroOrUnknown": integer
  rounding beyond Double precision, the sliver, clamping and empty bars.
- "testTreeRowsDrawMapSwatchesAndFocusRelativeUsageBars" and
  "testUnknownAllocationRowKeepsAnEmptyUsageBar": native cells use map colors,
  focus-relative bars and decorative accessibility state.

[IntegrationFixTests.swift](../native/ExplorerModelTests/IntegrationFixTests.swift):

- "testRejectedExecutionRecoversCurrentPresentationWithoutRemoval".
- "testFailedReplacementRestoresOldTreeAndFrameWithoutClearingError".
- "testParentRequestsCoalesceActualQueriesAndDropObsoletePendingWork".
- "testQueuedParentDoesNotExecuteAfterSelectionOrSessionChanges".
- "testEmptyDirectoryRightDoesNotExpandOrSelectNextSibling" uses offscreen key events.
- "testHistorySelectionOutsideSliceRestoresVisibleRowWithoutRevealOrScroll".

Foreground input, modal operations and screenshots are tested separately in
[ExplorerUITests.swift](../native/ExplorerTests/ExplorerUITests.swift), as listed in
[native-explorer.md](native-explorer.md). They require an unlocked interactive console.
