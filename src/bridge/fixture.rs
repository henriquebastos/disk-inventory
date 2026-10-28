//! Purpose-built native-free scenarios. These paths exist only in MemoryFileSystem.
use super::BridgeError;
use crate::{
    Counters, Entry, Kind, Map,
    explorer::Explorer,
    operations::{
        Identity, LiveMetadata, OperationSession,
        memory::{MemoryFileSystem, TrashBehavior},
    },
};
use std::path::{Path, PathBuf};

pub(super) fn metadata(inode: u64, kind: Kind, bytes: u64) -> LiveMetadata {
    LiveMetadata {
        identity: Identity { device: 1, inode },
        kind,
        allocated_bytes: bytes,
        logical_bytes: bytes.saturating_add(17),
        links: 1,
        mode: 0o600,
        modified_seconds: 123,
        modified_nanoseconds: 456,
        created_seconds: 100,
        flags: 0,
        mount: false,
    }
}
pub(super) fn map() -> Result<Map, BridgeError> {
    build_map(false, false)
}
fn build_map(presentation: bool, visible_travel: bool) -> Result<Map, BridgeError> {
    let mut map = Map {
        root: PathBuf::from("/Workspace"),
        nodes: vec![],
        names: vec![],
        counters: Counters::default(),
        error_samples: vec![],
    };
    let mut add = |parent, name: &[u8], inode, kind, bytes, links| {
        map.add(
            parent,
            name,
            Entry {
                kind,
                dev: 1,
                ino: inode,
                flags: 0,
                links,
                allocation: Some(bytes),
                mount: 0,
            },
        )
    };
    add(0, b"", 1, Kind::Dir, 10, 1)?;
    let small = add(0, b"small-files", 2, Kind::Dir, 20, 1)?;
    for i in 0..if presentation { 128 } else { 16 } {
        add(
            small,
            format!("small-{i:02}").as_bytes(),
            if presentation { 1000 + i } else { 10 + i },
            Kind::File,
            64,
            1,
        )?;
    }
    add(
        0,
        b"large-file",
        30,
        Kind::File,
        if presentation {
            4096
        } else {
            (1u64 << 53) + 123
        },
        1,
    )?;
    add(0, b"zero-byte", 31, Kind::File, 0, 1)?;
    add(0, b"hardlink-a", 32, Kind::File, 512, 2)?;
    add(0, b"hardlink-b", 32, Kind::File, 512, 2)?;
    // A larger owned Trash directory separates the source and destination map regions.
    add(
        0,
        b"trash",
        33,
        Kind::Dir,
        if visible_travel { 16384 } else { 30 },
        1,
    )?;
    add(0, b"raw-\xff", 34, Kind::File, 128, 1)?;
    map.aggregate()?;
    Ok(map)
}
// Bounded visual edge cases, separate from every accepted boundary/failure scenario.
fn visual_details_map() -> Result<Map, BridgeError> {
    let mut map = Map {
        root: PathBuf::from("/Workspace"),
        nodes: vec![],
        names: vec![],
        counters: Counters::default(),
        error_samples: vec![],
    };
    let mut inode = 2000;
    let mut add = |parent, name: &[u8], kind, bytes| {
        inode += 1;
        map.add(
            parent,
            name,
            Entry {
                kind,
                dev: 1,
                ino: inode,
                flags: 0,
                links: 1,
                allocation: Some(bytes),
                mount: 0,
            },
        )
    };
    add(0, b"", Kind::Dir, 10)?;
    let collection = add(0, b"collection", Kind::Dir, 20)?;
    let nested = add(collection, b"nested-group", Kind::Dir, 30)?;
    add(nested, b"first-file", Kind::File, 2048)?;
    add(nested, b"second-file", Kind::File, 2048)?;
    add(collection, b"sibling-file", Kind::File, 2048)?;
    let mut parent = add(0, b"long-path", Kind::Dir, 20)?;
    for i in 0..3 {
        parent = add(
            parent,
            format!("segment-{i}-{}", "long-name-".repeat(18)).as_bytes(),
            Kind::Dir,
            20,
        )?;
    }
    let target = add(parent, b"target-directory", Kind::Dir, 20)?;
    add(target, b"payload", Kind::File, 6144)?;
    map.aggregate()?;
    Ok(map)
}

/// Builder for `prototype-home`: the data tree of the specialist prototype
/// (`Explorer Window.dc.html`, `data()`), ported step by step. Directories own zero bytes.
struct PrototypeHome {
    map: Map,
    /// The prototype's Park-Miller generator: `s = s * 16807 % 2147483647`, seed 11.
    seed: u64,
    inode: u64,
}
impl PrototypeHome {
    fn add(&mut self, parent: u32, name: &str, kind: Kind, bytes: u64) -> Result<u32, BridgeError> {
        self.inode += 1;
        Ok(self.map.add(
            parent,
            name.as_bytes(),
            Entry {
                kind,
                dev: 1,
                ino: self.inode,
                flags: 0,
                links: 1,
                allocation: Some(bytes),
                mount: 0,
            },
        )?)
    }
    fn dir(&mut self, parent: u32, name: &str) -> Result<u32, BridgeError> {
        self.add(parent, name, Kind::Dir, 0)
    }
    /// The prototype's `F(name, parent, kind, gb)`.
    fn file(&mut self, parent: u32, name: &str, gigabytes: f64) -> Result<(), BridgeError> {
        self.add(parent, name, Kind::File, round_half_up(gigabytes * 1e9))?;
        Ok(())
    }
    /// The prototype's `gen(parent, kind, count, total, base)`. Weights are `r()^2.4 + 0.015`
    /// in generator order; each size is `round(w / sum * total * 1e9)`, so the sum can differ
    /// from `total` by a few bytes, as in the prototype.
    fn generate(
        &mut self,
        parent: u32,
        extensions: &[&str],
        count: usize,
        total_gigabytes: f64,
        base: &str,
    ) -> Result<(), BridgeError> {
        let weights: Vec<f64> = (0..count)
            .map(|_| {
                self.seed = self.seed * 16807 % 2_147_483_647;
                (self.seed as f64 / 2_147_483_647.0).powf(2.4) + 0.015
            })
            .collect();
        let sum = weights.iter().fold(0.0, |a, b| a + b);
        for (i, weight) in weights.iter().enumerate() {
            let name = format!("{base} {:02}.{}", i + 1, extensions[i % extensions.len()]);
            let bytes = round_half_up(weight / sum * total_gigabytes * 1e9);
            self.add(parent, &name, Kind::File, bytes)?;
        }
        Ok(())
    }
}
/// JavaScript `Math.round` for non-negative values: halves round up.
fn round_half_up(value: f64) -> u64 {
    let floor = value.floor();
    (if value - floor >= 0.5 {
        floor + 1.0
    } else {
        floor
    }) as u64
}
// The prototype's `EXT` table: file kinds by extension, used in this order.
const VIDEO: &[&str] = &["mov", "mp4"];
const IMAGE: &[&str] = &["heic", "jpg", "png"];
const AUDIO: &[&str] = &["m4a", "wav"];
const ARCHIVE: &[&str] = &["zip", "dmg"];
const CODE: &[&str] = &["o", "swiftmodule", "js"];
const CACHE: &[&str] = &["db", "cache"];
const DATA: &[&str] = &["sqlite", "bin"];
const DOC: &[&str] = &["pdf", "pages", "txt"];
/// The prototype's 236.9 GB home folder `/Users/ana`. Calls follow the prototype's order,
/// because each `generate` call advances the shared generator. One folder differs:
/// `Developer/CoreDevice` is the prototype's `CoreSimulator`, because visible text may say
/// "simulated" only in the fixture window title.
pub(super) fn prototype_home_map() -> Result<Map, BridgeError> {
    prototype_home(false)
}
/// `nested_trash` adds `Projects/.Trash` after every prototype entry, so the prototype's files
/// keep their sizes and the parity test needs no change.
fn prototype_home(nested_trash: bool) -> Result<Map, BridgeError> {
    let mut h = PrototypeHome {
        map: Map {
            root: PathBuf::from("/Users/ana"),
            nodes: vec![],
            names: vec![],
            counters: Counters::default(),
            error_samples: vec![],
        },
        seed: 11,
        inode: 3000,
    };
    h.add(0, "", Kind::Dir, 0)?;
    let library = h.dir(0, "Library")?;
    let developer = h.dir(library, "Developer")?;
    let xcode = h.dir(developer, "Xcode")?;
    let derived = h.dir(xcode, "DerivedData")?;
    for (name, total) in [
        ("Atlas-bqzk", 18.0),
        ("Website-hrtd", 12.0),
        ("Playground-ajwe", 7.0),
        ("Widgets-cmno", 4.2),
    ] {
        let project = h.dir(derived, name)?;
        h.generate(project, CODE, 14, total, "Build")?;
    }
    let archives = h.dir(xcode, "Archives")?;
    h.generate(archives, ARCHIVE, 6, 5.8, "Atlas")?;
    let devices = h.dir(developer, "CoreDevice")?;
    h.generate(devices, DATA, 18, 13.1, "Device")?;
    let support = h.dir(library, "Application Support")?;
    h.generate(support, DATA, 30, 22.4, "store")?;
    let caches = h.dir(library, "Caches")?;
    h.generate(caches, CACHE, 40, 17.6, "cache")?;
    let containers = h.dir(library, "Containers")?;
    h.generate(containers, DATA, 20, 8.9, "container")?;
    let movies = h.dir(0, "Movies")?;
    let trip = h.dir(movies, "Trip 2025.fcpbundle")?;
    h.generate(trip, VIDEO, 22, 31.4, "Clip")?;
    h.file(movies, "Interview raw.mov", 14.2)?;
    h.generate(movies, VIDEO, 8, 5.6, "Screen Recording")?;
    let downloads = h.dir(0, "Downloads")?;
    h.file(downloads, "Install macOS.app", 13.4)?;
    h.file(downloads, "dataset-2026.zip", 8.7)?;
    h.generate(downloads, ARCHIVE, 10, 3.1, "download")?;
    h.generate(downloads, IMAGE, 12, 2.2, "IMG")?;
    h.generate(downloads, DOC, 15, 1.4, "Invoice")?;
    let pictures = h.dir(0, "Pictures")?;
    let photos = h.dir(pictures, "Photos Library.photoslibrary")?;
    h.generate(photos, IMAGE, 70, 21.8, "IMG")?;
    let projects = h.dir(0, "Projects")?;
    let atlas = h.dir(projects, "atlas")?;
    let modules = h.dir(atlas, "node_modules")?;
    h.generate(modules, CODE, 60, 5.9, "module")?;
    h.generate(atlas, CODE, 30, 3.2, "src")?;
    h.generate(projects, IMAGE, 8, 3.6, "Render")?;
    let website = h.dir(projects, "website")?;
    h.generate(website, CODE, 25, 2.4, "page")?;
    let music = h.dir(0, "Music")?;
    h.generate(music, AUDIO, 30, 4.8, "Track")?;
    let trash = h.dir(0, ".Trash")?;
    h.generate(trash, VIDEO, 3, 1.4, "Old clip")?;
    h.generate(trash, DOC, 8, 0.9, "old")?;
    let documents = h.dir(0, "Documents")?;
    h.generate(documents, DOC, 40, 3.9, "Doc")?;
    h.file(documents, "notes.txt", 0.000004)?;
    h.file(documents, "empty.log", 0.0)?;
    if nested_trash {
        let nested = h.dir(projects, ".Trash")?;
        h.generate(nested, VIDEO, 4, 4.0, "Old render")?;
    }
    h.map.aggregate()?;
    Ok(h.map)
}

/// `file-type-colors`: files whose extension the prototype table lacked, and files without an
/// extension in Git object storage and cache folders, beside gray controls (a document, a
/// numbered file, a file without an extension and an `objects` folder outside `.git`).
fn file_type_colors_map() -> Result<Map, BridgeError> {
    let mut h = PrototypeHome {
        map: Map {
            root: PathBuf::from("/Users/ana"),
            nodes: vec![],
            names: vec![],
            counters: Counters::default(),
            error_samples: vec![],
        },
        seed: 11,
        inode: 5000,
    };
    h.add(0, "", Kind::Dir, 0)?;
    for (folders, name, gigabytes) in [
        (
            &["Projects", "atlas", ".git", "objects", "3a"][..],
            "7c91d04e",
            3.0,
        ),
        (
            &["Projects", "atlas", ".git", "objects", "pack"],
            "pack-1f2e.pack",
            4.0,
        ),
        (
            &["Projects", "atlas", ".git", "objects", "pack"],
            "pack-1f2e.idx",
            1.2,
        ),
        (&["Projects", "atlas", "objects"], "b4e0aa", 1.5),
        (&["Projects", "atlas", "build"], "libcore.dylib", 2.0),
        (&["Projects", "atlas", "src"], "index.ts", 1.0),
        (&["Library", "Caches", "com.example.viewer"], "5C1D27", 2.5),
        (
            &[
                ".cache",
                "huggingface",
                "hub",
                "models--org--model",
                "blobs",
            ],
            "9f86d081",
            3.5,
        ),
        (
            &[".npm", "_cacache", "content-v2", "sha512", "ab"],
            "cd34ef",
            1.4,
        ),
        (
            &[".local", "share", "pnpm", "store", "v3", "files", "00"],
            "1a2b3c",
            1.6,
        ),
        (&["Data"], "events.jsonl", 3.0),
        (&["Data"], "table.csv", 1.0),
        (&["Media"], "clip.webm", 2.2),
        (&["Media"], "voice.opus", 1.3),
        (&["Media"], "sketch.psd", 1.1),
        (&["Downloads"], "tool.whl", 1.0),
        (&["Documents"], "report.pdf", 1.8),
        (&["Documents"], "notes", 0.9),
        (&["Documents"], "segment.1", 0.8),
    ] {
        let mut parent = 0;
        for folder in folders {
            parent = match h.map.nodes.iter().enumerate().position(|(id, node)| {
                id != 0 && node.parent == parent && h.map.basename(id) == folder.as_bytes()
            }) {
                Some(id) => id as u32,
                None => h.dir(parent, folder)?,
            };
        }
        h.file(parent, name, gigabytes)?;
    }
    h.map.aggregate()?;
    Ok(h.map)
}

pub(super) fn session(scenario: &str) -> Result<OperationSession<MemoryFileSystem>, BridgeError> {
    if ![
        "dix",
        "dix-wide",
        "dix-deep",
        "ordinary",
        "presentation",
        "prototype-home",
        "prototype-home-refresh",
        "prototype-home-nested-trash",
        "file-type-colors",
        "visual-details",
        "metadata-delay",
        "trash-inside",
        "presentation-trash-inside",
        "presentation-trash-late-target",
        "trash-outside",
        "metadata-failure",
        "permission-failure",
        "changed-target",
        "partial-deletion",
        "trash-unknown",
        "trash-missing",
        "trash-failure",
        "unknown-allocation",
    ]
    .contains(&scenario)
    {
        return Err(BridgeError::InvalidInput {
            message: format!("unknown fixture scenario: {scenario}"),
        });
    }
    let map = if matches!(scenario, "dix" | "dix-wide" | "dix-deep") {
        dix_map(
            if scenario == "dix-wide" {
                100_000
            } else {
                2000
            },
            scenario == "dix-deep",
        )?
    } else if scenario == "visual-details" {
        visual_details_map()?
    } else if matches!(scenario, "prototype-home" | "prototype-home-refresh") {
        prototype_home_map()?
    } else if scenario == "prototype-home-nested-trash" {
        prototype_home(true)?
    } else if scenario == "file-type-colors" {
        file_type_colors_map()?
    } else if matches!(
        scenario,
        "presentation"
            | "metadata-delay"
            | "presentation-trash-inside"
            | "presentation-trash-late-target"
    ) {
        build_map(true, scenario == "presentation-trash-inside")?
    } else {
        map()?
    };
    let mut fs = MemoryFileSystem::default();
    fs.insert("/", metadata(90, Kind::Dir, 0));
    fs.insert("/.Trash", metadata(91, Kind::Dir, 0));
    for id in 0..map.nodes.len() {
        let node = &map.nodes[id];
        let mut m = metadata(node.ino, node.kind, node.raw);
        m.links = node.links;
        fs.insert(map.path(id), m);
    }
    let root = Path::new("/Workspace");
    fs.trash_behavior = TrashBehavior::MoveTo(PathBuf::from("/.Trash/moved"));
    if scenario == "prototype-home-refresh" {
        // A refresh reads every directory for 300 ms, so its progress and Stop are visible,
        // and it finds one new live file that the saved inventory does not have.
        for id in 0..map.nodes.len() {
            if map.nodes[id].kind == Kind::Dir {
                fs.metadata_delays
                    .insert(map.path(id), std::time::Duration::from_millis(300));
            }
        }
        fs.insert(
            "/Users/ana/Library/Caches/new cache.db",
            metadata(900_000, Kind::File, 2_000_000_000),
        );
    }
    match scenario {
        "metadata-delay" => {
            fs.metadata_delays
                .insert(root.join("large-file"), std::time::Duration::from_secs(1));
        }
        "trash-inside" | "presentation-trash-inside" | "presentation-trash-late-target" => {
            fs.trash_behavior = TrashBehavior::MoveTo(root.join("trash/moved"))
        }
        "metadata-failure" => {
            fs.metadata_errors.insert(root.join("large-file"));
        }
        "permission-failure" => {
            fs.unreadable.insert(root.join("small-files"));
            fs.remove_failure_after = Some(0);
        }
        "changed-target" => fs.insert(root.join("large-file"), metadata(99, Kind::File, 100)),
        "partial-deletion" => {
            fs.remove_failure_after = Some(1);
            fs.unreadable_after_partial = true;
        }
        "trash-unknown" => fs.unknown_scope = true,
        "trash-missing" => {
            fs.trash_behavior = TrashBehavior::MissingDestination(PathBuf::from("/.Trash/moved"))
        }
        "trash-failure" => fs.trash_behavior = TrashBehavior::Fail("Trash access denied".into()),
        "unknown-allocation" => {
            // Singleton observations deliberately disagree for a new shared identity.
            fs.insert(root.join("unknown-a"), metadata(100, Kind::File, 100));
            fs.insert(root.join("unknown-b"), metadata(100, Kind::File, 500));
        }
        _ => {}
    }
    Ok(OperationSession::new(Explorer::from_map(map)?, fs))
}

#[cfg(test)]
mod prototype_parity_tests;

fn dix_map(count: u32, deep: bool) -> Result<Map, BridgeError> {
    let mut map = Map {
        root: "/Workspace".into(),
        nodes: vec![],
        names: vec![],
        counters: Counters::default(),
        error_samples: vec![],
    };
    let mut inode = 10_000;
    let mut add = |parent, name: &[u8], kind, bytes| {
        inode += 1;
        map.add(
            parent,
            name,
            Entry {
                kind,
                dev: 1,
                ino: inode,
                flags: 0,
                links: 1,
                allocation: Some(bytes),
                mount: 0,
            },
        )
    };
    add(0, b"", Kind::Dir, 4096)?;
    if deep {
        let mut parent = 0;
        for i in 0..80 {
            parent = add(parent, format!("level-{i}").as_bytes(), Kind::Dir, 0)?;
        }
        add(parent, b"bottom.txt", Kind::File, 4096)?;
        map.aggregate()?;
        return Ok(map);
    }
    let dense = add(0, b"Projects", Kind::Dir, 4096)?;
    for i in 0..count {
        add(
            dense,
            format!(
                "asset-{i:06}.{}",
                ["png", "rs", "txt", "mp3"][i as usize % 4]
            )
            .as_bytes(),
            Kind::File,
            4096 * (1 + (i % 16) as u64),
        )?;
    }
    let tiny = add(0, b"Tiny files", Kind::Dir, 4096)?;
    let nested = add(tiny, b"Notes", Kind::Dir, 4096)?;
    add(nested, b"four-KiB.txt", Kind::File, 4096)?;
    add(nested, b"eight-KiB.png", Kind::File, 8192)?;
    add(nested, b"empty.txt", Kind::File, 0)?;
    add(0, b"Movie.mov", Kind::File, 64 * 1024 * 1024)?;
    map.aggregate()?;
    Ok(map)
}
