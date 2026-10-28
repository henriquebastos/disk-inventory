//! Pure, viewport-bounded treemap refinement over the saved child index.
use crate::{
    Kind,
    explorer::{EntryHandle, Explorer},
    invalid,
};
use std::{cmp::Ordering, collections::BinaryHeap, io};

pub const MAX_RECTANGLES: usize = 4096;
pub const MAX_DEPTH: u32 = 64;
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub(crate) fn area(self) -> f64 {
        self.width * self.height
    }
    pub(crate) fn valid(self) -> bool {
        [
            self.x,
            self.y,
            self.width,
            self.height,
            self.area(),
            self.x + self.width,
            self.y + self.height,
        ]
        .iter()
        .all(|v| v.is_finite())
            && self.width > 0.0
            && self.height > 0.0
            && self.area() > 0.0
            && self.x + self.width > self.x
            && self.y + self.height > self.y
    }
    pub(crate) fn contains(self, other: Self) -> bool {
        // Allow ordinary coordinate roundoff without accepting drift comparable
        // to a region's size at large origins.
        let slack = |origin: f64, extent: f64| {
            let magnitude = origin.abs().max((origin + extent).abs()).max(extent);
            (magnitude * f64::EPSILON * 16.0).min(extent * 1e-9)
        };
        let x_slack = slack(self.x, self.width);
        let y_slack = slack(self.y, self.height);
        other.valid()
            && other.x >= self.x - x_slack
            && other.y >= self.y - y_slack
            && other.x + other.width <= self.x + self.width + x_slack
            && other.y + other.height <= self.y + self.height + y_slack
    }
}
#[derive(Clone, Copy, Debug)]
pub struct LayoutOptions {
    pub viewport: Rect,
    /// Total leaf + grouping rectangles, not a per-directory limit.
    pub max_rectangles: usize,
    /// Minimum projected child area; smaller children remain in a rollup.
    pub min_area: f64,
    pub max_depth: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TileKind {
    /// Entire entry subtree, not just its own allocation.
    Entry(EntryHandle),
    /// Unexpanded children plus this directory's own accounted allocation.
    /// Not an actionable entry. Use the directory's paged outline to inspect it.
    Rollup {
        directory: EntryHandle,
        omitted_children: usize,
    },
}
#[derive(Clone, Copy, Debug)]
pub struct Tile {
    pub kind: TileKind,
    pub rect: Rect,
    pub bytes: u64,
    pub depth: u32,
    pub parent: Option<EntryHandle>,
}
#[derive(Clone, Copy, Debug)]
pub struct Group {
    pub directory: EntryHandle,
    pub rect: Rect,
    pub depth: u32,
    pub parent: Option<EntryHandle>,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LayoutWork {
    pub entries_examined: usize,
    /// At most twice the rectangle budget, including rejected subdivisions.
    pub child_ids_examined: usize,
    pub directories_expanded: usize,
}
#[derive(Debug)]
pub struct Layout {
    pub focus: EntryHandle,
    pub total_bytes: u64,
    /// Disjoint proportional regions whose integer weights sum to total_bytes.
    pub tiles: Vec<Tile>,
    /// Overlays only: never add these to the byte or area sum.
    pub groups: Vec<Group>,
    pub work: LayoutWork,
}
#[derive(Clone, Copy, Debug)]
struct Pending {
    tile: Tile,
    id: u32,
}
impl PartialEq for Pending {
    fn eq(&self, other: &Self) -> bool {
        (self.tile.bytes, self.id) == (other.tile.bytes, other.id)
    }
}
impl Eq for Pending {}
impl PartialOrd for Pending {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Pending {
    fn cmp(&self, other: &Self) -> Ordering {
        self.tile
            .bytes
            .cmp(&other.tile.bytes)
            .then_with(|| other.id.cmp(&self.id))
    }
}
impl Explorer {
    /// Largest regions refine first. Only bounded prefixes of reached directories
    /// are read; the remainder is known by subtracting from saved subtree totals.
    /// Repeated calls do not scan, sort or reconstruct the inventory.
    pub fn layout(&self, focus: EntryHandle, options: LayoutOptions) -> io::Result<Layout> {
        self.layout_with_limits(focus, options, MAX_RECTANGLES, MAX_DEPTH, false)
    }
    pub(crate) fn layout_with_limits(
        &self,
        focus: EntryHandle,
        options: LayoutOptions,
        rectangle_limit: usize,
        depth_limit: u32,
        cumulative_endpoints: bool,
    ) -> io::Result<Layout> {
        self.layout_with_trash(
            focus,
            options,
            rectangle_limit,
            depth_limit,
            cumulative_endpoints,
            false,
        )
    }
    /// The design's Trash rule: a directory named `.Trash` that is a direct child of the
    /// inventory root. A volume scan has no such child, so it shows no Trash region.
    pub(crate) fn is_root_trash(&self, id: u32) -> bool {
        let node = &self.map.nodes[id as usize];
        id != 0
            && node.parent == 0
            && node.kind == Kind::Dir
            && self.map.basename(id as usize) == b".Trash"
    }
    /// `whole_root_trash` keeps the root Trash as one tile, never reading its children.
    /// Only a root focus expands the root, so a Trash focus or a focus inside it draws
    /// its children normally.
    pub(crate) fn layout_with_trash(
        &self,
        focus: EntryHandle,
        options: LayoutOptions,
        rectangle_limit: usize,
        depth_limit: u32,
        cumulative_endpoints: bool,
        whole_root_trash: bool,
    ) -> io::Result<Layout> {
        let id = self.resolve(focus)?;
        if self.map.nodes[id as usize].kind != Kind::Dir {
            return Err(invalid("layout focus must be a directory"));
        }
        if !options.viewport.valid()
            || !options.min_area.is_finite()
            || options.min_area < 0.0
            || !(1..=rectangle_limit).contains(&options.max_rectangles)
            || options.max_depth > depth_limit
        {
            return Err(invalid("invalid treemap geometry or detail limits"));
        }
        let total_bytes = self.map.nodes[id as usize].subtree;
        // Subnormal per-byte geometry cannot reliably preserve proportional area.
        // Reject it rather than silently returning zero-sized positive-byte tiles.
        if total_bytes != 0
            && [
                options.viewport.width,
                options.viewport.height,
                options.viewport.area(),
            ]
            .iter()
            .any(|side| !(side / total_bytes as f64).is_normal())
        {
            return Err(invalid(
                "viewport is too small for proportional allocation geometry",
            ));
        }
        let mut result = Layout {
            focus,
            total_bytes,
            tiles: Vec::new(),
            groups: Vec::new(),
            work: LayoutWork::default(),
        };
        if total_bytes == 0 {
            return Ok(result);
        }
        let mut pending = BinaryHeap::from([Pending {
            id,
            tile: Tile {
                kind: TileKind::Entry(focus),
                rect: options.viewport,
                bytes: total_bytes,
                depth: 0,
                parent: None,
            },
        }]);
        while let Some(Pending { id, tile }) = pending.pop() {
            result.work.entries_examined += 1;
            // Retaining the parent as a group costs one slot, so every refinement
            // consumes budget even along single-child directory chains.
            let slots = options.max_rectangles
                - result.tiles.len()
                - result.groups.len()
                - pending.len()
                - 1;
            let children = self.child_ids(id);
            // Rejected subdivisions still consume work, even though their output
            // slots remain available to other regions.
            let child_budget = 2 * options.max_rectangles - result.work.child_ids_examined;
            if child_budget == 0
                || tile.depth >= options.max_depth
                || slots < 2
                || children.is_empty()
                || tile.rect.area() < options.min_area
            {
                result.tiles.push(tile);
                continue;
            }
            let mut parts = Vec::new();
            let mut remaining = tile.bytes;
            // Reserve one slot for a rollup; this also bounds work on huge fanout.
            for &child in children.iter().take((slots - 1).min(child_budget)) {
                result.work.child_ids_examined += 1;
                let bytes = self.map.nodes[child as usize].subtree;
                if bytes == 0
                    || bytes as f64 / tile.bytes as f64 * tile.rect.area() < options.min_area
                {
                    break;
                }
                parts.push(Tile {
                    kind: TileKind::Entry(self.handle(child)),
                    rect: tile.rect,
                    bytes,
                    depth: tile.depth + 1,
                    parent: Some(self.handle(id)),
                });
                remaining -= bytes;
            }
            if parts.is_empty() {
                result.tiles.push(tile);
                continue;
            }
            if remaining != 0 {
                parts.push(Tile {
                    kind: TileKind::Rollup {
                        directory: self.handle(id),
                        omitted_children: children.len() - parts.len(),
                    },
                    rect: tile.rect,
                    bytes: remaining,
                    depth: tile.depth + 1,
                    parent: Some(self.handle(id)),
                });
            }
            // Rounded endpoints can collapse or escape a subdivision. Keep the
            // parent intact when its children cannot form valid regions.
            if !squarify(&mut parts, tile.rect, tile.bytes, cumulative_endpoints) {
                result.tiles.push(tile);
                continue;
            }
            result.groups.push(Group {
                directory: self.handle(id),
                rect: tile.rect,
                depth: tile.depth,
                parent: tile.parent,
            });
            result.work.directories_expanded += 1;
            for part in parts {
                match part.kind {
                    TileKind::Entry(handle)
                        if self.map.nodes[handle.index() as usize].kind == Kind::Dir
                            && !(whole_root_trash && self.is_root_trash(handle.index())) =>
                    {
                        pending.push(Pending {
                            id: handle.index(),
                            tile: part,
                        })
                    }
                    _ => result.tiles.push(part),
                }
            }
        }
        Ok(result)
    }
}

// Squarified rows, O(k log k) for a bounded prefix, not the inventory. Ratios of
// remaining integer weights avoid catastrophic cancellation on skewed trees.
fn squarify(
    parts: &mut [Tile],
    mut rect: Rect,
    mut remaining: u64,
    cumulative_endpoints: bool,
) -> bool {
    let bounds = rect;
    let total = remaining;
    parts.sort_by_key(|part| std::cmp::Reverse(part.bytes));
    let mut start = 0;
    while start < parts.len() {
        if !bounds.contains(rect) {
            return false;
        }
        let side = rect.width.min(rect.height);
        let scale = rect.area() / remaining as f64;
        let mut end = start + 1;
        let mut weight = parts[start].bytes;
        let worst = |weight: u64, last: usize| {
            let area = weight as f64 * scale;
            let max = parts[start].bytes as f64 * scale;
            let min = parts[last].bytes as f64 * scale;
            ((side / area) * (side / area) * max).max((area / side) * (area / side) / min)
        };
        while end < parts.len() && worst(weight + parts[end].bytes, end) <= worst(weight, end - 1) {
            weight += parts[end].bytes;
            end += 1;
        }
        let vertical = rect.width >= rect.height;
        let fraction = weight as f64 / remaining as f64;
        let mut thickness = if vertical { rect.width } else { rect.height } * fraction;
        // Native diagrams can refine very large sibling prefixes at nonzero origins.
        // Close shared edges instead of accumulating per-child lengths, which can
        // drift outside the row and reject the entire subdivision. Keep the legacy
        // API's arithmetic unchanged; both modes share scoring and orientation.
        let origin = if vertical { rect.x } else { rect.y };
        let far = if vertical {
            bounds.x + bounds.width
        } else {
            bounds.y + bounds.height
        };
        let edge = if remaining == weight {
            far
        } else {
            origin + thickness
        };
        if cumulative_endpoints {
            thickness = edge - origin;
        }
        let row = if vertical {
            Rect {
                width: thickness,
                ..rect
            }
        } else {
            Rect {
                height: thickness,
                ..rect
            }
        };
        if !rect.contains(row) {
            return false;
        }
        let cross_origin = if vertical { rect.y } else { rect.x };
        let cross_length = if vertical { rect.height } else { rect.width };
        let mut offset = cross_origin;
        let mut used = 0u64;
        for part in &mut parts[start..end] {
            let mut length = if vertical { rect.height } else { rect.width }
                * (part.bytes as f64 / weight as f64);
            used += part.bytes;
            let end = if used == weight {
                cross_origin + cross_length
            } else {
                cross_origin + cross_length * (used as f64 / weight as f64)
            };
            if cumulative_endpoints {
                length = end - offset;
            }
            part.rect = if vertical {
                Rect {
                    x: rect.x,
                    y: offset,
                    width: thickness,
                    height: length,
                }
            } else {
                Rect {
                    x: offset,
                    y: rect.y,
                    width: length,
                    height: thickness,
                }
            };
            if !row.contains(part.rect) {
                return false;
            }
            if cumulative_endpoints {
                // Endpoint closure must not trade coverage for distorted byte area
                // when the coordinate origin is too large to represent the split.
                let expected = bounds.area() * (part.bytes as f64 / total as f64);
                if (part.rect.area() - expected).abs() > expected * 1e-9 {
                    return false;
                }
            }
            if cumulative_endpoints {
                offset = end;
            } else {
                offset += length;
            }
        }
        let rest = (remaining - weight) as f64 / remaining as f64;
        if cumulative_endpoints {
            if vertical {
                rect.x = edge;
                rect.width = far - edge;
            } else {
                rect.y = edge;
                rect.height = far - edge;
            }
        } else if vertical {
            rect.x += thickness;
            rect.width *= rest;
        } else {
            rect.y += thickness;
            rect.height *= rest;
        }
        remaining -= weight;
        start = end;
    }
    true
}
