//! Map pixels of the fixture scenarios, measured on the Rust bitmap at the size of the map in
//! the default window on a 2x display. These replace window screenshots in UI tests: the app
//! draws this bitmap 1:1 (`testWindowShowsTheMapBitmapOneToOneAndTheTreeInSystemColors` checks
//! that).
use super::*;
use std::collections::HashMap;

const WIDTH: u32 = 1700;
const HEIGHT: u32 = 1420;
const APPEARANCES: [MapAppearance; 4] = [
    MapAppearance::Light,
    MapAppearance::Dark,
    MapAppearance::LightIncreasedContrast,
    MapAppearance::DarkIncreasedContrast,
];
/// The prototype palette by kind, as `type_color` draws it.
const KINDS: [(&str, [u8; 3]); 8] = [
    ("video", [79, 138, 198]),
    ("image", [81, 153, 98]),
    ("audio", [171, 109, 166]),
    ("archive", [173, 124, 47]),
    ("app", [133, 122, 196]),
    ("code", [0, 153, 160]),
    ("cache", [190, 110, 82]),
    ("data", [138, 140, 52]),
];

fn contrast_ratio(a: [u8; 3], b: [u8; 3]) -> f64 {
    let luminance = |c: [u8; 3]| {
        let linear = |v: u8| {
            let v = v as f64 / 255.0;
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
    };
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}
fn pixel(image: &BitmapRecord, x: u32, y: u32) -> [u8; 3] {
    let at = (y * image.width + x) as usize * 4;
    [image.rgba[at], image.rgba[at + 1], image.rgba[at + 2]]
}
/// HSV hue in degrees and saturation. The gradient, the seam and the shade mix a kind color
/// with white or black, which keeps its hue.
fn hue(c: [u8; 3]) -> (f64, f64) {
    let (r, g, b) = (c[0] as f64, c[1] as f64, c[2] as f64);
    let high = r.max(g).max(b);
    let span = high - r.min(g).min(b);
    if span == 0.0 {
        return (0.0, 0.0);
    }
    let h = if high == r {
        (g - b) / span
    } else if high == g {
        2.0 + (b - r) / span
    } else {
        4.0 + (r - g) / span
    };
    ((h * 60.0 + 360.0) % 360.0, span / high)
}
/// For each kind, the share of pixels sampled every third pixel in the area whose hue is
/// nearest that kind; pixels with saturation up to 0.25 count as neutral gray.
fn kind_shares(image: &BitmapRecord, area: Rectangle) -> (HashMap<&'static str, f64>, f64) {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let (mut neutral, mut total) = (0, 0);
    let mut y = area.y as u32;
    while (y as f64) < area.y + area.height {
        let mut x = area.x as u32;
        while (x as f64) < area.x + area.width {
            total += 1;
            let (h, saturation) = hue(pixel(image, x, y));
            if saturation <= 0.25 {
                neutral += 1;
            } else {
                let distance = |kind: &[u8; 3]| {
                    let d = (hue(*kind).0 - h).abs();
                    d.min(360.0 - d)
                };
                let nearest = KINDS
                    .iter()
                    .min_by(|a, b| distance(&a.1).total_cmp(&distance(&b.1)))
                    .unwrap();
                *counts.entry(nearest.0).or_default() += 1;
            }
            x += 3;
        }
        y += 3;
    }
    let total = total.max(1) as f64;
    (
        counts
            .into_iter()
            .map(|(kind, n)| (kind, n as f64 / total))
            .collect(),
        neutral as f64 / total,
    )
}
fn inset(r: Rectangle, by: f64) -> Rectangle {
    Rectangle {
        x: r.x + by,
        y: r.y + by,
        width: r.width - 2.0 * by,
        height: r.height - 2.0 * by,
    }
}
fn whole(image: &BitmapRecord) -> Rectangle {
    Rectangle {
        x: 0.0,
        y: 0.0,
        width: image.width as f64,
        height: image.height as f64,
    }
}
/// The entry at `path`, one name per level below the root.
fn at_path(s: &ExplorerSession, path: &[&str]) -> Arc<EntryKey> {
    path.iter()
        .fold(s.status().unwrap().root.key, |parent, name| {
            child(s, parent, name.as_bytes()).unwrap_or_else(|| panic!("no {name} in {path:?}"))
        })
}
fn frame(s: &Arc<ExplorerSession>, focus: Arc<EntryKey>, a: MapAppearance) -> Arc<DiagramFrame> {
    s.clone().diagram(focus, WIDTH, HEIGHT, a).unwrap()
}
/// First pixel column or row inside a tile edge on the backing grid.
fn edge(point: f64) -> u32 {
    (point - 0.5).ceil() as u32
}
/// Pixels of `key` in the frame and the mean colors of its plain and striped interior bands.
fn trash_bands(
    frame: &DiagramFrame,
    key: &Arc<EntryKey>,
    a: MapAppearance,
) -> (usize, [u8; 3], [u8; 3]) {
    let image = frame.bitmap();
    let fill = crate::diagram::MapAppearance::from(a).trash();
    let region = frame.region(key.clone()).unwrap().unwrap();
    let (x0, y0) = (edge(region.x), edge(region.y));
    let (x1, y1) = (
        edge(region.x + region.width),
        edge(region.y + region.height),
    );
    let (mut count, mut sums) = (0, [[0u64; 4]; 2]);
    for y in y0 + 1..y1 - 1 {
        for x in x0 + 1..x1 - 1 {
            if x % 3 == 0 && y % 3 == 0 {
                let hit = frame.hit(x, y).unwrap().unwrap();
                assert!(hit.entry.key.same_entry(key.clone()), "one Trash region");
            }
            count += 1;
            let diagonal = (x1 - x) as f64 + (y1 - y) as f64 - 1.0;
            let band = &mut sums[fill.striped(diagonal) as usize];
            for (c, v) in pixel(&image, x, y).into_iter().enumerate() {
                band[c] += v as u64;
            }
            band[3] += 1;
        }
    }
    let mean = |s: [u64; 4]| std::array::from_fn(|c| (s[c] / s[3].max(1)) as u8);
    (count, mean(sums[0]), mean(sums[1]))
}
/// Focused on a `.Trash`, the map draws its files: no pixel is the `.Trash` itself, and video
/// colors cover more than 30% of the map.
fn assert_focused_trash_shows_files(s: &Arc<ExplorerSession>, trash: &Arc<EntryKey>) {
    for a in APPEARANCES {
        let inside = frame(s, trash.clone(), a);
        let image = inside.bitmap();
        for y in (0..HEIGHT).step_by(13) {
            for x in (0..WIDTH).step_by(13) {
                let hit = inside.hit(x, y).unwrap().unwrap();
                assert!(!hit.entry.key.same_entry(trash.clone()), "{a:?}: {x},{y}");
            }
        }
        let video = kind_shares(&image, whole(&image)).0["video"];
        assert!(video > 0.3, "{a:?}: focused Trash video share {video}");
    }
}

/// A file name and the kind of its map tile, or "gray".
type Expected = (&'static str, &'static str);

#[test]
fn file_type_colors_fixture_keeps_type_colors_in_light_and_dark_and_inside_object_folders() {
    let s = session("file-type-colors");
    let home = [
        ("7c91d04e", "archive"),
        ("pack-1f2e.pack", "archive"),
        ("pack-1f2e.idx", "archive"),
        ("libcore.dylib", "code"),
        ("index.ts", "code"),
        ("5C1D27", "cache"),
        ("9f86d081", "cache"),
        ("cd34ef", "cache"),
        ("1a2b3c", "cache"),
        ("events.jsonl", "data"),
        ("table.csv", "data"),
        ("clip.webm", "video"),
        ("voice.opus", "audio"),
        ("sketch.psd", "image"),
        ("tool.whl", "archive"),
        // Objects of a submodule, a nested submodule, a submodule named after its path
        // `vendor/lib` and a bare repository.
        ("a1b2c3d4", "archive"),
        ("0d9e8f7a", "archive"),
        ("f0e1d2c3", "archive"),
        ("cdef0123", "archive"),
        // Gray controls: a document, `objects` outside `.git`, no extension, a numbered file,
        // `modules/<name>/objects` outside `.git`.
        ("report.pdf", "gray"),
        ("b4e0aa", "gray"),
        ("notes", "gray"),
        ("segment.1", "gray"),
        ("e9d8c7", "gray"),
    ];
    // A focus inside Git object storage keeps the archive color for its loose objects.
    let objects = ["7c91d04e", "pack-1f2e.pack", "pack-1f2e.idx"].map(|n| (n, "archive"));
    let scenes: [(&[&str], &[Expected]); 5] = [
        (&[], &home),
        (&["Projects", "atlas", ".git", "objects"], &objects),
        (
            &[
                "Projects",
                "atlas",
                ".git",
                "modules",
                "vendor-lib",
                "modules",
                "deep-dep",
                "objects",
            ],
            &[("0d9e8f7a", "archive")],
        ),
        (
            &[
                "Projects", "atlas", ".git", "modules", "vendor", "lib", "objects",
            ],
            &[("f0e1d2c3", "archive")],
        ),
        (
            &["Projects", "mirror.git", "objects"],
            &[("cdef0123", "archive")],
        ),
    ];
    for a in [MapAppearance::Light, MapAppearance::Dark] {
        for (path, files) in scenes {
            let frame = frame(&s, at_path(&s, path), a);
            let image = frame.bitmap();
            let targets = frame.targets().unwrap();
            for &(name, kind) in files {
                let target = targets
                    .iter()
                    .find(|t| t.entry.display_name == name)
                    .unwrap_or_else(|| panic!("{a:?} {path:?}: no map tile for {name}"));
                let (shares, neutral) = kind_shares(&image, inset(target.rect, 6.0));
                let share = if kind == "gray" {
                    neutral
                } else {
                    shares.get(kind).copied().unwrap_or(0.0)
                };
                assert!(
                    share >= 0.9,
                    "{a:?} {path:?}: {name} must be {kind}, share {share}"
                );
            }
        }
    }
}

#[test]
fn prototype_home_map_shows_every_kind_color_and_presentation_stays_gray() {
    for (scenario, a) in [
        ("prototype-home", MapAppearance::Dark),
        ("prototype-home", MapAppearance::Light),
        ("presentation", MapAppearance::Dark),
        ("presentation", MapAppearance::Light),
    ] {
        let s = session(scenario);
        let image = frame(&s, s.status().unwrap().root.key, a).bitmap();
        let (shares, neutral) = kind_shares(&image, inset(whole(&image), 40.0));
        let mut shown: Vec<&str> = shares
            .iter()
            .filter(|&(_, &share)| share >= 0.005)
            .map(|(&kind, _)| kind)
            .collect();
        shown.sort();
        if scenario == "prototype-home" {
            assert_eq!(
                shown,
                [
                    "app", "archive", "audio", "cache", "code", "data", "image", "video"
                ],
                "{a:?}: every colored kind covers at least 0.5% of the map"
            );
            assert!(neutral >= 0.005, "{a:?}: gray documents {neutral}");
        } else {
            assert!(
                shown.is_empty(),
                "{a:?}: presentation files have no extension: {shown:?}"
            );
        }
    }
}

#[test]
fn presentation_hatch_follows_appearance_and_increase_contrast_strengthens_its_stripes() {
    let s = session("presentation");
    for a in APPEARANCES {
        let frame = frame(&s, s.status().unwrap().root.key, a);
        let image = frame.bitmap();
        let mut levels: HashMap<[u8; 3], usize> = HashMap::new();
        // Every second pixel in each direction.
        for y in (0..HEIGHT).step_by(2) {
            for x in (0..WIDTH).step_by(2) {
                if !frame.hit(x, y).unwrap().unwrap().actionable {
                    *levels.entry(pixel(&image, x, y)).or_default() += 1;
                }
            }
        }
        let pixels: usize = levels.values().sum();
        assert!(pixels > 500, "{a:?}: the map shows aggregate hatch");
        let mut stripes: Vec<[u8; 3]> = levels.keys().copied().collect();
        stripes.sort();
        assert_eq!(stripes.len(), 2, "{a:?}: two neutral stripes {stripes:?}");
        let (dark, light) = (stripes[0], stripes[1]);
        assert!(
            stripes
                .iter()
                .all(|c| c.iter().max().unwrap() - c.iter().min().unwrap() <= 8)
        );
        let ratio = contrast_ratio(light, dark);
        match a {
            MapAppearance::Light | MapAppearance::LightIncreasedContrast => {
                assert!(
                    dark[1] > 140,
                    "{a:?}: light hatch on a light window {dark:?}"
                )
            }
            _ => assert!(
                light[1] < 110,
                "{a:?}: dark hatch on a dark window {light:?}"
            ),
        }
        match a {
            MapAppearance::LightIncreasedContrast | MapAppearance::DarkIncreasedContrast => {
                assert!(ratio > 2.3, "{a:?}: stronger hatch stripes {ratio}")
            }
            _ => assert!(ratio < 1.5, "{a:?}: subtle hatch stripes {ratio}"),
        }
    }
}

#[test]
fn presentation_large_file_seam_is_the_design_inset_and_darker_with_increase_contrast() {
    let s = session("presentation");
    let key = find(&s, b"large-file");
    for a in APPEARANCES {
        let frame = frame(&s, s.status().unwrap().root.key, a);
        let image = frame.bitmap();
        let r = frame.region(key.clone()).unwrap().unwrap();
        // The top seam against the next row inside the tile, at three columns.
        let y = edge(r.y);
        let ratio = [0.25, 0.5, 0.75]
            .map(|f| {
                let x = edge(r.x + r.width * f);
                contrast_ratio(pixel(&image, x, y), pixel(&image, x, y + 1))
            })
            .into_iter()
            .fold(f64::MAX, f64::min);
        match a {
            MapAppearance::LightIncreasedContrast | MapAppearance::DarkIncreasedContrast => {
                assert!(ratio >= 3.0, "{a:?} seam {ratio}")
            }
            // The ordinary seam is the design's inset (x0.55); Increase Contrast is stronger.
            _ => assert!((1.8..3.0).contains(&ratio), "{a:?} seam {ratio}"),
        }
    }
}

#[test]
fn prototype_home_tiles_have_the_design_seam_on_all_four_sides() {
    let s = session("prototype-home");
    for a in APPEARANCES {
        let frame = frame(&s, s.status().unwrap().root.key, a);
        let image = frame.bitmap();
        let targets = frame.targets().unwrap();
        // Up to six of the largest tiles with a unique name, each at least 40 points.
        let mut tiles: Vec<&DiagramSelection> = targets
            .iter()
            .filter(|t| {
                t.rect.width >= 80.0
                    && t.rect.height >= 80.0
                    && targets
                        .iter()
                        .filter(|o| o.entry.display_name == t.entry.display_name)
                        .count()
                        == 1
            })
            .collect();
        tiles.sort_by(|p, q| {
            (q.rect.width * q.rect.height).total_cmp(&(p.rect.width * p.rect.height))
        });
        tiles.truncate(6);
        assert!(tiles.len() >= 3, "{a:?}: {} large tiles", tiles.len());
        let floor = match a {
            MapAppearance::LightIncreasedContrast | MapAppearance::DarkIncreasedContrast => 3.0,
            _ => 1.8,
        };
        for tile in tiles {
            let r = tile.rect;
            let (x0, y0) = (edge(r.x), edge(r.y));
            let (x1, y1) = (edge(r.x + r.width), edge(r.y + r.height));
            for side in 0..4 {
                let ratio = [0.25, 0.5, 0.75]
                    .map(|f| {
                        let x = x0 + ((x1 - x0) as f64 * f) as u32;
                        let y = y0 + ((y1 - y0) as f64 * f) as u32;
                        // The seam pixel against the next pixel inside the same tile.
                        let (seam, inside) = match side {
                            0 => ((x0, y), (x0 + 1, y)),
                            1 => ((x, y0), (x, y0 + 1)),
                            2 => ((x1 - 1, y), (x1 - 2, y)),
                            _ => ((x, y1 - 1), (x, y1 - 2)),
                        };
                        contrast_ratio(
                            pixel(&image, seam.0, seam.1),
                            pixel(&image, inside.0, inside.1),
                        )
                    })
                    .into_iter()
                    .fold(f64::MAX, f64::min);
                assert!(
                    ratio >= floor,
                    "{a:?} {} side {side}: seam {ratio}",
                    tile.entry.display_name
                );
            }
        }
    }
}

#[test]
fn prototype_home_root_trash_is_one_striped_region_until_focused() {
    let s = session("prototype-home");
    let trash = find(&s, b".Trash");
    for a in APPEARANCES {
        let home = frame(&s, s.status().unwrap().root.key, a);
        let (count, plain, striped) = trash_bands(&home, &trash, a);
        let ratio = contrast_ratio(plain, striped);
        assert!(count > 500, "{a:?}: Trash pixels {count}");
        let floor = match a {
            MapAppearance::LightIncreasedContrast | MapAppearance::DarkIncreasedContrast => 1.4,
            _ => 1.1,
        };
        assert!(ratio > floor, "{a:?}: visible stripes {ratio}");
    }
    assert_focused_trash_shows_files(&s, &trash);
}

#[test]
fn prototype_home_nested_trash_is_striped_at_its_parent_level_until_focused() {
    let s = session("prototype-home-nested-trash");
    let projects = find(&s, b"Projects");
    let trash = child(&s, projects.clone(), b".Trash").unwrap();
    for a in APPEARANCES {
        let parent = frame(&s, projects.clone(), a);
        let (count, plain, striped) = trash_bands(&parent, &trash, a);
        assert!(count > 500, "{a:?}: Projects/.Trash pixels {count}");
        let floor = match a {
            MapAppearance::LightIncreasedContrast | MapAppearance::DarkIncreasedContrast => 1.4,
            _ => 1.1,
        };
        let ratio = contrast_ratio(plain, striped);
        assert!(ratio > floor, "{a:?}: visible stripes {ratio}");
    }
    assert_focused_trash_shows_files(&s, &trash);
}
