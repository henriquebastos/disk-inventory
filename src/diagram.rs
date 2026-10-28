//! Immutable pixel-addressable saved diagram. No filesystem access or bridge object per tile.
use crate::{
    Kind,
    explorer::{EntryHandle, Explorer},
    invalid,
    layout::{Layout, LayoutOptions, Rect, TileKind},
};
use std::{io, time::Instant};
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
    /// Compatibility statistic: zero now that rasterization has no surface map.
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
/// System appearance of a raster. It changes only the aggregate hatch, the Trash fill and the
/// tile seam; the type palette, the gradient, the geometry and the owners stay the same.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapAppearance {
    Light,
    Dark,
    LightIncreasedContrast,
    DarkIncreasedContrast,
}
impl MapAppearance {
    /// Multiplier for the one-pixel seam on all four edges of a file or Trash tile. 0.55 is
    /// the design's `inset 0 0 0 0.5px rgba(0,0,0,.45)` on a 2x backing grid. Increase
    /// Contrast keeps at least 3:1 against the next interior pixel of the same tile at every
    /// gradient position.
    pub fn seam_factor(self) -> f64 {
        match self {
            Self::Light | Self::Dark => 0.55,
            Self::LightIncreasedContrast | Self::DarkIncreasedContrast => 0.33,
        }
    }
    /// The design's TRASH fill for the root Trash. Dark uses the design values; light uses a
    /// light base with black stripes. Increase Contrast uses 30% stripes. Its dark base is
    /// lighter, because no dark seam reaches 3:1 against the design's dark base.
    pub fn trash(self) -> TrashFill {
        let (base, stripe) = match self {
            Self::Dark => ([68, 72, 78], [255, 255, 255]),
            Self::DarkIncreasedContrast => ([132, 136, 142], [255, 255, 255]),
            Self::Light | Self::LightIncreasedContrast => ([185, 190, 198], [0, 0, 0]),
        };
        let stripe_alpha = match self {
            Self::Light | Self::Dark => 0.09,
            Self::LightIncreasedContrast | Self::DarkIncreasedContrast => 0.30,
        };
        TrashFill {
            base,
            stripe,
            stripe_alpha,
        }
    }
    /// Two sRGB stripes of the aggregate hatch.
    pub fn hatch(self) -> [[u8; 3]; 2] {
        match self {
            Self::Dark => [[59, 59, 62], [38, 38, 40]],
            Self::Light => [[206, 206, 210], [184, 184, 189]],
            Self::DarkIncreasedContrast => [[96, 96, 100], [28, 28, 30]],
            Self::LightIncreasedContrast => [[232, 232, 236], [150, 150, 156]],
        }
    }
}
/// `repeating-linear-gradient(-45deg, STRIPE 0 4px, transparent 4px 9px)` over
/// `linear-gradient(155deg, rgba(255,255,255,.08), rgba(0,0,0,.12))` over `base`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrashFill {
    pub base: [u8; 3],
    pub stripe: [u8; 3],
    pub stripe_alpha: f64,
}
impl TrashFill {
    /// `position` runs along the 155-degree gradient. `diagonal` is the backing-pixel sum
    /// of the distances to the right and the bottom edge; the stripe widths assume a 2x
    /// backing grid (4 and 9 points). A seam pixel (`seam` < 1) darkens the darker band, so
    /// the seam line has no stripes and keeps its contrast against both bands.
    pub fn color(self, position: f64, diagonal: f64, seam: f64) -> [u8; 3] {
        let position = position.clamp(0.0, 1.0);
        // Premultiplied interpolation between 8% white and 12% black.
        let alpha = 0.08 * (1.0 - position) + 0.12 * position;
        let white = 255.0 * 0.08 * (1.0 - position);
        let striped = if seam < 1.0 {
            self.stripe[0] < self.base[0]
        } else {
            self.striped(diagonal)
        };
        std::array::from_fn(|c| {
            let mut value = self.base[c] as f64 * (1.0 - alpha) + white;
            if striped {
                value =
                    value * (1.0 - self.stripe_alpha) + self.stripe[c] as f64 * self.stripe_alpha;
            }
            (value * seam).round() as u8
        })
    }
    /// Stripes cover 4 of every 9 points along the -45-degree direction.
    pub fn striped(self, diagonal: f64) -> bool {
        (diagonal * std::f64::consts::FRAC_1_SQRT_2 / 2.0).rem_euclid(9.0) < 4.0
    }
}
impl Explorer {
    pub fn diagram(
        &self,
        focus: EntryHandle,
        width: u32,
        height: u32,
        appearance: MapAppearance,
    ) -> io::Result<Diagram> {
        let pixels = (width as usize)
            .checked_mul(height as usize)
            .ok_or_else(|| invalid("diagram dimensions overflow"))?;
        if pixels == 0 || pixels > MAX_PIXELS {
            return Err(invalid("diagram requires 1..=4000000 pixels"));
        }
        let start = Instant::now();
        let layout = self.layout_with_trash(
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
            true,
        )?;
        let layout_micros = start.elapsed().as_micros() as u64;
        let start = Instant::now();
        let mut rgba = vec![0u8; pixels * 4];
        let mut owners = vec![0; pixels];
        let mut aggregate_pixels = 0;
        let seam = appearance.seam_factor();
        let [hatch_light, hatch_dark] = appearance.hatch();
        let trash_fill = appearance.trash();
        for (i, tile) in layout.tiles.iter().enumerate() {
            let file = match tile.kind {
                TileKind::Entry(key) if self.map.nodes[key.index() as usize].kind != Kind::Dir => {
                    Some(key)
                }
                _ => None,
            };
            // The root Trash is one actionable region that selects the Trash directory.
            let trash =
                matches!(tile.kind, TileKind::Entry(key) if self.is_root_trash(key.index()));
            let actionable = file.is_some() || trash;
            let color = file.map(|key| type_color(self.map.basename(key.index() as usize)));
            let r = tile.rect;
            // CSS 155deg direction, normalized by the rectangle's projected span.
            let gradient_span = r.width * GRADIENT_X + r.height * GRADIENT_Y;
            let x0 = (r.x - 0.5).ceil().max(0.0) as usize;
            let y0 = (r.y - 0.5).ceil().max(0.0) as usize;
            let x1 = ((r.x + r.width - 0.5).ceil().max(0.0) as usize).min(width as usize);
            let y1 = ((r.y + r.height - 0.5).ceil().max(0.0) as usize).min(height as usize);
            if !actionable {
                aggregate_pixels += (x1 - x0) * (y1 - y0);
            }
            let seamed = x1 - x0 > 3 && y1 - y0 > 3;
            for y in y0..y1 {
                for x in x0..x1 {
                    let position = ((x as f64 + 0.5 - r.x) * GRADIENT_X
                        + (y as f64 + 0.5 - r.y) * GRADIENT_Y)
                        / gradient_span;
                    let border = seamed && (x == x0 || y == y0 || x + 1 == x1 || y + 1 == y1);
                    let edge = if border { seam } else { 1.0 };
                    let rgb = if let Some(color) = color {
                        gradient_color(color, position, edge)
                    } else if trash {
                        let diagonal = (x1 - x) as f64 + (y1 - y) as f64 - 1.0;
                        trash_fill.color(position, diagonal, edge)
                    } else if (x + y) % 4 < 2 {
                        // Aggregates are visibly distinct and never become file action targets.
                        hatch_light
                    } else {
                        hatch_dark
                    };
                    let at = y * width as usize + x;
                    debug_assert_eq!(owners[at], 0, "overlapping diagram pixels");
                    owners[at] = (i + 1) as u32 | if actionable { 0 } else { 1 << 31 };
                    rgba[at * 4..at * 4 + 3].copy_from_slice(&rgb);
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
            surface_payload_bytes: 0,
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
// Restrained top-left highlight to bottom-right shade, without inherited depth ridges.
const GRADIENT_X: f64 = 0.42261826174069944; // sin(155deg)
const GRADIENT_Y: f64 = 0.9063077870366499; // -cos(155deg)
/// `seam` is 1.0 inside a tile. On each of the four edges it is the appearance's seam
/// factor, the prototype's half-point black inset on the backing grid.
fn gradient_color(color: [u8; 3], position: f64, seam: f64) -> [u8; 3] {
    let position = position.clamp(0.0, 1.0);
    let highlight = 0.14 * (1.0 - position / 0.55).max(0.0);
    let shade = 0.16 * ((position - 0.55) / 0.45).max(0.0);
    color.map(|channel| {
        let value = (channel as f64 + (255.0 - channel as f64) * highlight) * (1.0 - shade);
        (value * seam).round() as u8
    })
}
/// Base file-tile color before the gradient; tree swatches reuse it through the bridge.
pub(crate) fn type_color(name: &[u8]) -> [u8; 3] {
    // Only known ASCII extensions matter; inspect at most twelve saved name bytes, without allocation.
    let tail = &name[name.len().saturating_sub(12)..];
    let ext = tail
        .iter()
        .rposition(|&b| b == b'.')
        .map(|at| &tail[at + 1..])
        .unwrap_or_default();
    // Prototype OKLCH L=.62 C=.11 hues, converted once to clipped 8-bit sRGB;
    // documents/unknown use C=.02 H=260. No runtime color-space conversion.
    let types: &[(&[&[u8]], [u8; 3])] = &[
        (&[b"png", b"jpg", b"jpeg", b"gif", b"heic"], [81, 153, 98]),
        (&[b"mp4", b"mov", b"mkv", b"avi"], [79, 138, 198]),
        (&[b"mp3", b"wav", b"flac", b"m4a"], [171, 109, 166]),
        (&[b"zip", b"gz", b"dmg"], [173, 124, 47]),
        (&[b"app"], [133, 122, 196]),
        (
            &[
                b"rs",
                b"swift",
                b"c",
                b"h",
                b"m",
                b"js",
                b"py",
                b"o",
                b"swiftmodule",
            ],
            [0, 153, 160],
        ),
        (&[b"db", b"cache"], [190, 110, 82]),
        (&[b"bin", b"sqlite"], [138, 140, 52]),
    ];
    types
        .iter()
        .find(|(extensions, _)| extensions.iter().any(|e| ext.eq_ignore_ascii_case(e)))
        .map(|(_, color)| *color)
        .unwrap_or([127, 135, 147])
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn type_palette_matches_prototype_and_flat_gradient_is_monotonic() {
        for (name, color) in [
            (b"a.png".as_slice(), [81, 153, 98]),
            (b"a.mov", [79, 138, 198]),
            (b"a.wav", [171, 109, 166]),
            (b"a.zip", [173, 124, 47]),
            (b"a.app", [133, 122, 196]),
            (b"a.swift", [0, 153, 160]),
            (b"a.cache", [190, 110, 82]),
            (b"a.bin", [138, 140, 52]),
            (b"a.pdf", [127, 135, 147]),
        ] {
            assert_eq!(type_color(name), color);
            assert_eq!(gradient_color(color, 0.55, 1.0), color);
            let mut previous = gradient_color(color, 0.0, 1.0);
            for step in 1..=100 {
                let next = gradient_color(color, step as f64 / 100.0, 1.0);
                assert!((0..3).all(|c| next[c] <= previous[c]));
                previous = next;
            }
            assert_eq!(
                gradient_color(color, 1.0, 1.0),
                color.map(|c| (c as f64 * 0.84).round() as u8)
            );
        }
        assert_eq!(type_color(b"a.png"), type_color(b"other.PNG"));
        assert_eq!(type_color(b"a.mov"), type_color(b"other.mp4"));
        assert_eq!(type_color(b"no-extension"), type_color(b"unknown.zzz"));
        assert_eq!(type_color(b"\xff.PNG"), type_color(b"a.png"));
        assert_eq!(type_color(b"notpng"), type_color(b"unknown.zzz"));
        assert_eq!(type_color(b"a.swiftmodule"), type_color(b"a.swift"));
        assert_eq!(type_color(b"a.SQLITE"), type_color(b"a.bin"));
        assert_eq!(type_color(b"notsqlite"), type_color(b"unknown.zzz"));
    }
}

#[cfg(test)]
mod scale_tests;
