//! Saved-inventory lifecycle. Opening and entry access never consult the source tree.
use crate::{Counters, Kind, Map, Method, invalid, scan, snapshot};
use std::{
    fs, io,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

/// Native bulk collection with four workers by default.
#[derive(Clone, Copy, Debug)]
pub struct ScanOptions {
    pub workers: usize,
}
impl Default for ScanOptions {
    fn default() -> Self {
        Self { workers: 4 }
    }
}
impl ScanOptions {
    fn validate(self) -> io::Result<()> {
        if ![1, 2, 4, 8].contains(&self.workers) {
            return Err(invalid("workers must be 1, 2, 4, or 8"));
        }
        Ok(())
    }
}

/// A sync scan was partial; the previously saved inventory was not replaced.
#[derive(Debug)]
pub struct IncompleteSync {
    pub counters: Counters,
}
impl std::fmt::Display for IncompleteSync {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "sync incomplete ({} scan errors); saved inventory unchanged",
            self.counters.errors
        )
    }
}
impl std::error::Error for IncompleteSync {}

#[derive(Debug)]
pub struct Inventory {
    map: Map,
}

/// Paths are raw bytes relative to `Inventory::root`; the root entry has an empty path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedEntry {
    pub relative_path: Vec<u8>,
    pub kind: Kind,
    pub allocated_bytes: u64,
    pub accounted_bytes: u64,
    pub subtree_bytes: u64,
}

impl Inventory {
    /// Create a new snapshot. A partial scan is saved and exposed through `is_partial`.
    pub fn create(root: &Path, output: &Path, options: ScanOptions) -> io::Result<Self> {
        options.validate()?;
        let output = destination(root, output)?;
        match fs::symlink_metadata(&output) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "snapshot output already exists",
                ));
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let map = scan(root, Method::Bulk, options.workers)?.map;
        snapshot::save_new(&map, &output)?;
        Ok(Self { map })
    }

    /// Eagerly load and validate saved data, without checking the recorded root.
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            map: snapshot::load(path)?,
        })
    }

    /// Rescan the entire saved root. Fatal and partial scans leave old bytes untouched.
    /// An `io::Error` containing `IncompleteSync` distinguishes a partial scan.
    pub fn sync(path: &Path, options: ScanOptions) -> io::Result<Self> {
        options.validate()?;
        let root = Self::open(path)?.root().to_path_buf();
        let path = destination(&root, path)?;
        let map = scan(&root, Method::Bulk, options.workers)?.map;
        if map.counters.errors != 0 {
            return Err(io::Error::other(IncompleteSync {
                counters: map.counters,
            }));
        }
        snapshot::save(&map, &path)?;
        Ok(Self { map })
    }

    pub fn root(&self) -> &Path {
        &self.map.root
    }
    pub fn counters(&self) -> &Counters {
        &self.map.counters
    }
    pub fn is_partial(&self) -> bool {
        self.map.counters.errors != 0
    }
    pub fn len(&self) -> usize {
        self.map.nodes.len()
    }
    pub fn is_empty(&self) -> bool {
        self.map.nodes.is_empty()
    }
    pub fn subtree_bytes(&self) -> u64 {
        self.map.nodes[0].subtree
    }
    pub fn entry(&self, index: usize) -> Option<SavedEntry> {
        self.map.nodes.get(index).map(|node| SavedEntry {
            relative_path: self.map.relative_path(index),
            kind: node.kind,
            allocated_bytes: node.raw,
            accounted_bytes: node.accounted,
            subtree_bytes: node.subtree,
        })
    }
    /// Snapshot order, not canonical path order. Allocates only the current entry's path.
    pub fn entries(&self) -> impl ExactSizeIterator<Item = SavedEntry> + '_ {
        (0..self.len()).map(|id| self.entry(id).unwrap())
    }
}

fn destination(root: &Path, output: &Path) -> io::Result<PathBuf> {
    // Validate the same no-symlink root policy as the collector before resolving aliases.
    if !root.is_absolute() {
        return Err(invalid("root must be absolute"));
    }
    let root_metadata = crate::open_directory(root)?.metadata()?;
    let root = fs::canonicalize(root)?;
    let name = output
        .file_name()
        .ok_or_else(|| invalid("snapshot needs a file name"))?;
    let parent = output
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let parent = fs::canonicalize(parent)?;
    if parent.starts_with(&root) {
        return Err(invalid("snapshot output must be outside the scanned root"));
    }
    // macOS firmlink aliases need not have the same canonical spelling.
    for ancestor in parent.ancestors() {
        let metadata = fs::metadata(ancestor)?;
        if (metadata.dev(), metadata.ino()) == (root_metadata.dev(), root_metadata.ino()) {
            return Err(invalid("snapshot output must be outside the scanned root"));
        }
    }
    let output = parent.join(name);
    // Sync must not follow a destination symlink to another snapshot.
    if fs::symlink_metadata(&output).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(invalid("snapshot output must not be a symlink"));
    }
    Ok(output)
}
