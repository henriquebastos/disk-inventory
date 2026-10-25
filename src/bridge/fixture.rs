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
    for i in 0..16 {
        add(
            small,
            format!("small-{i:02}").as_bytes(),
            10 + i,
            Kind::File,
            64,
            1,
        )?;
    }
    add(0, b"large-file", 30, Kind::File, (1u64 << 53) + 123, 1)?;
    add(0, b"zero-byte", 31, Kind::File, 0, 1)?;
    add(0, b"hardlink-a", 32, Kind::File, 512, 2)?;
    add(0, b"hardlink-b", 32, Kind::File, 512, 2)?;
    add(0, b"trash", 33, Kind::Dir, 30, 1)?;
    add(0, b"raw-\xff", 34, Kind::File, 128, 1)?;
    map.aggregate()?;
    Ok(map)
}
pub(super) fn session(scenario: &str) -> Result<OperationSession<MemoryFileSystem>, BridgeError> {
    if ![
        "ordinary",
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
    let map = map()?;
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
