//! Immutable pixel-addressable saved diagram. No filesystem access or bridge object per tile.
use crate::{
    Kind,
    explorer::{EntryHandle, Explorer},
    invalid,
    layout::{Layout, LayoutOptions, Rect, TileKind},
};
use std::{collections::HashMap, io, time::Instant};
pub const MAX_PIXELS: usize = 4_000_000;
pub const MAX_REGIONS: usize = 1_000_000;
#[derive(Clone, Copy, Debug)]
pub struct DiagramStats {
    pub pixels: usize,
    pub tiles: usize,
    pub groups: usize,
    pub child_visits: usize,
    /// Counted vector payload, excluding allocator/FFI/image-provider copies.
    pub retained_payload_bytes: usize,
    /// Counted cushion surface map payload; not a peak-memory estimate.
    pub surface_payload_bytes: usize,
    pub layout_micros: u64,
    pub raster_micros: u64,
    pub aggregate_pixels: usize,
}
pub struct Diagram {
    pub width: u32,
    pub height: u32,
    pub layout: Layout,
    rgba: Vec<u8>,
    owners: Vec<u32>,
    pub stats: DiagramStats,
}
#[derive(Clone, Copy)]
pub struct DiagramHit {
    pub key: EntryHandle,
    pub actionable: bool,
    pub rect: Rect,
    pub bytes: u64,
}
impl Explorer {
    pub fn diagram(&self, focus: EntryHandle, width: u32, height: u32) -> io::Result<Diagram> {
        let pixels = (width as usize)
            .checked_mul(height as usize)
            .ok_or_else(|| invalid("diagram dimensions overflow"))?;
        if pixels == 0 || pixels > MAX_PIXELS {
            return Err(invalid("diagram requires 1..=4000000 pixels"));
        }
        let start = Instant::now();
        let layout = self.layout_with_limits(
            focus,
            LayoutOptions {
                viewport: Rect {
                    x: 0.0,
                    y: 0.0,
                    width: width as f64,
                    height: height as f64,
                },
                max_rectangles: pixels.clamp(1, MAX_REGIONS),
                min_area: 1.0,
                max_depth: u32::MAX,
            },
            MAX_REGIONS,
            u32::MAX,
            true,
        )?;
        let layout_micros = start.elapsed().as_micros() as u64;
        let start = Instant::now();
        let mut rgba = vec![0u8; pixels * 4];
        let mut owners = vec![0; pixels];
        let mut surfaces: HashMap<EntryHandle, [f64; 4]> = HashMap::new();
        for group in &layout.groups {
            let parent = group
                .parent
                .and_then(|p| surfaces.get(&p).copied())
                .unwrap_or([0.0; 4]);
            surfaces.insert(group.directory, ridge(parent, group.rect, group.depth));
        }
        let surface_payload_bytes =
            surfaces.capacity() * std::mem::size_of::<(EntryHandle, [f64; 4])>();
        let mut aggregate_pixels = 0;
        for (i, tile) in layout.tiles.iter().enumerate() {
            let file = match tile.kind {
                TileKind::Entry(key) if self.map.nodes[key.index() as usize].kind != Kind::Dir => {
                    Some(key)
                }
                _ => None,
            };
            let color = file
                .map(|key| type_color(self.map.basename(key.index() as usize)))
                .unwrap_or([100, 105, 115]);
            let parent = tile
                .parent
                .and_then(|p| surfaces.get(&p).copied())
                .unwrap_or([0.0; 4]);
            let c = ridge(parent, tile.rect, tile.depth);
            let r = tile.rect;
            let x0 = (r.x - 0.5).ceil().max(0.0) as usize;
            let y0 = (r.y - 0.5).ceil().max(0.0) as usize;
            let x1 = ((r.x + r.width - 0.5).ceil().max(0.0) as usize).min(width as usize);
            let y1 = ((r.y + r.height - 0.5).ceil().max(0.0) as usize).min(height as usize);
            if file.is_none() {
                aggregate_pixels += (x1 - x0) * (y1 - y0);
            }
            for y in y0..y1 {
                for x in x0..x1 {
                    let dx = 2.0 * c[0] * (x as f64 + 0.5) + c[1];
                    let dy = 2.0 * c[2] * (y as f64 + 0.5) + c[3];
                    let light = (0.50
                        + 0.50
                            * ((1.0 - 0.25 * dx - 0.35 * dy) / (1.0 + dx * dx + dy * dy).sqrt())
                                .max(0.0))
                    .clamp(0.35, 1.0);
                    let border = if x1 - x0 > 3 && y1 - y0 > 3 && (x == x0 || y == y0) {
                        0.60
                    } else {
                        1.0
                    };
                    let at = y * width as usize + x;
                    debug_assert_eq!(owners[at], 0, "overlapping diagram pixels");
                    owners[at] = (i + 1) as u32 | if file.is_none() { 1 << 31 } else { 0 };
                    for channel in 0..3 {
                        rgba[at * 4 + channel] = (color[channel] as f64 * light * border) as u8;
                    }
                    rgba[at * 4 + 3] = 255;
                }
            }
        }
        let retained_payload_bytes = rgba.capacity()
            + owners.capacity() * 4
            + layout.tiles.capacity() * std::mem::size_of::<crate::layout::Tile>()
            + layout.groups.capacity() * std::mem::size_of::<crate::layout::Group>();
        let stats = DiagramStats {
            pixels,
            tiles: layout.tiles.len(),
            groups: layout.groups.len(),
            child_visits: layout.work.child_ids_examined,
            retained_payload_bytes,
            surface_payload_bytes,
            layout_micros,
            raster_micros: start.elapsed().as_micros() as u64,
            aggregate_pixels,
        };
        Ok(Diagram {
            width,
            height,
            layout,
            rgba,
            owners,
            stats,
        })
    }
}
fn ridge(mut parent: [f64; 4], r: Rect, depth: u32) -> [f64; 4] {
    // The region envelope bounds depth below i32::MAX; underflow just removes negligible ridges.
    let h = 0.28 * r.width.min(r.height) * 0.80f64.powi(depth as i32);
    let ax = -4.0 * h / (r.width * r.width);
    let ay = -4.0 * h / (r.height * r.height);
    parent[0] += ax;
    parent[1] -= ax * (2.0 * r.x + r.width);
    parent[2] += ay;
    parent[3] -= ay * (2.0 * r.y + r.height);
    parent
}
fn type_color(name: &[u8]) -> [u8; 3] {
    // Only known ASCII extensions matter; inspect at most six saved name bytes, without allocation.
    let tail = &name[name.len().saturating_sub(6)..];
    let ext = tail
        .iter()
        .rposition(|&b| b == b'.')
        .map(|at| &tail[at + 1..])
        .unwrap_or_default();
    let types: &[(&[&[u8]], [u8; 3])] = &[
        (&[b"png", b"jpg", b"jpeg", b"gif", b"heic"], [221, 157, 72]),
        (&[b"mp4", b"mov", b"mkv", b"avi"], [92, 154, 215]),
        (&[b"mp3", b"wav", b"flac", b"m4a"], [173, 120, 208]),
        (
            &[b"rs", b"swift", b"c", b"h", b"m", b"js", b"py"],
            [88, 177, 141],
        ),
        (&[b"txt", b"md", b"pdf", b"doc"], [200, 134, 112]),
        (&[b"zip", b"gz", b"dmg"], [181, 169, 90]),
    ];
    types
        .iter()
        .find(|(extensions, _)| extensions.iter().any(|e| ext.eq_ignore_ascii_case(e)))
        .map(|(_, color)| *color)
        .unwrap_or([132, 150, 170])
}

impl Diagram {
    pub fn rgba(&self) -> &[u8] {
        &self.rgba
    }
    pub fn hit(&self, x: u32, y: u32) -> Option<DiagramHit> {
        if x >= self.width || y >= self.height {
            return None;
        }
        let owner = self.owners[y as usize * self.width as usize + x as usize];
        if owner == 0 {
            return None;
        }
        let tile = &self.layout.tiles[(owner & 0x7fff_ffff) as usize - 1];
        let (key, actionable) = match tile.kind {
            TileKind::Entry(key) => (key, owner & (1 << 31) == 0),
            TileKind::Rollup { directory, .. } => (directory, false),
        };
        Some(DiagramHit {
            key,
            actionable,
            rect: tile.rect,
            bytes: tile.bytes,
        })
    }
    pub fn region(&self, key: EntryHandle) -> Option<Rect> {
        self.layout
            .groups
            .iter()
            .find(|g| g.directory == key)
            .map(|g| g.rect)
            .or_else(|| {
                self.layout
                    .tiles
                    .iter()
                    .find(|t| matches!(t.kind,TileKind::Entry(k) if k==key))
                    .map(|t| t.rect)
            })
    }
}

mod strips;
pub(crate) use strips::place_strips;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn type_palette_is_extension_stable_and_cushion_ridges_are_not_flat() {
        assert_eq!(type_color(b"a.png"), type_color(b"other.PNG"));
        assert_eq!(type_color(b"a.mov"), type_color(b"other.mp4"));
        assert_ne!(type_color(b"a.png"), type_color(b"a.swift"));
        assert_eq!(type_color(b"no-extension"), type_color(b"unknown.zzz"));
        let c = ridge(
            [0.0; 4],
            Rect {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 50.0,
            },
            0,
        );
        assert!(c[0] < 0.0 && c[2] < 0.0);
        assert!((2.0 * c[0] * 50.0 + c[1]).abs() < 1e-12);
        assert!((2.0 * c[2] * 25.0 + c[3]).abs() < 1e-12);
        assert_ne!(2.0 * c[0] * 1.0 + c[1], 2.0 * c[0] * 99.0 + c[1]);
    }
}

#[cfg(test)]
mod scale_tests;
