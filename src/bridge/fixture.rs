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
    build_map(false)
}
fn build_map(presentation: bool) -> Result<Map, BridgeError> {
    let mut map = Map {
        root: PathBuf::from("/simulated-inventory"),
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
    add(0, b"trash", 33, Kind::Dir, 30, 1)?;
    add(0, b"raw-\xff", 34, Kind::File, 128, 1)?;
    map.aggregate()?;
    Ok(map)
}
// Bounded visual edge cases, separate from every accepted boundary/failure scenario.
fn visual_details_map() -> Result<Map, BridgeError> {
    let mut map = Map {
        root: PathBuf::from("/simulated-inventory"),
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

pub(super) fn session(scenario: &str) -> Result<OperationSession<MemoryFileSystem>, BridgeError> {
    if ![
        "dix",
        "dix-wide",
        "dix-deep",
        "ordinary",
        "presentation",
        "visual-details",
        "metadata-delay",
        "trash-inside",
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
            message: format!("unknown simulated scenario: {scenario}"),
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
    } else if matches!(scenario, "presentation" | "metadata-delay") {
        build_map(true)?
    } else {
        map()?
    };
    let mut fs = MemoryFileSystem::default();
    fs.insert("/", metadata(90, Kind::Dir, 0));
    fs.insert("/simulated-outside", metadata(91, Kind::Dir, 0));
    for id in 0..map.nodes.len() {
        let node = &map.nodes[id];
        let mut m = metadata(node.ino, node.kind, node.raw);
        m.links = node.links;
        fs.insert(map.path(id), m);
    }
    let root = Path::new("/simulated-inventory");
    fs.trash_behavior = TrashBehavior::MoveTo(PathBuf::from("/simulated-outside/moved"));
    match scenario {
        "metadata-delay" => {
            fs.metadata_delays
                .insert(root.join("large-file"), std::time::Duration::from_secs(1));
        }
        "trash-inside" => fs.trash_behavior = TrashBehavior::MoveTo(root.join("trash/moved")),
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
            fs.trash_behavior =
                TrashBehavior::MissingDestination(PathBuf::from("/simulated-outside/moved"))
        }
        "trash-failure" => fs.trash_behavior = TrashBehavior::Fail("simulated Trash denied".into()),
        "unknown-allocation" => {
            // Singleton observations deliberately disagree for a new shared identity.
            fs.insert(root.join("unknown-a"), metadata(100, Kind::File, 100));
            fs.insert(root.join("unknown-b"), metadata(100, Kind::File, 500));
        }
        _ => {}
    }
    Ok(OperationSession::new(Explorer::from_map(map)?, fs))
}

fn dix_map(count: u32, deep: bool) -> Result<Map, BridgeError> {
    let mut map = Map {
        root: "/simulated-inventory".into(),
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
