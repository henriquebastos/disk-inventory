#![cfg(target_os = "macos")]
pub mod explorer;
pub mod export;
pub mod inventory;
pub mod layout;
pub mod native;
pub mod snapshot;
use std::os::darwin::fs::MetadataExt as DarwinMetadataExt;

use std::{
    collections::{HashMap, HashSet, VecDeque},
    ffi::OsStr,
    fs::{self, File, Metadata, OpenOptions},
    io,
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Component, Path, PathBuf},
    sync::{Condvar, Mutex},
    time::{Duration, Instant},
};

pub fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
pub fn valid_basename(name: &[u8]) -> bool {
    !name.is_empty() && name != b"." && name != b".." && !name.contains(&0) && !name.contains(&b'/')
}
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        result.push(DIGITS[(b >> 4) as usize] as char);
        result.push(DIGITS[(b & 15) as usize] as char);
    }
    result
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Kind {
    File = 1,
    Dir = 2,
    Other = 3,
    Symlink = 4,
}
#[derive(Debug)]
pub struct Entry {
    pub kind: Kind,
    pub dev: u64,
    pub ino: u64,
    pub flags: u32,
    pub links: u32,
    pub allocation: Option<u64>,
    pub mount: u32,
}
impl Entry {
    pub fn symlink() -> Self {
        Self {
            kind: Kind::Symlink,
            dev: 0,
            ino: 0,
            flags: 0,
            links: 0,
            allocation: None,
            mount: 0,
        }
    }
    fn metadata(m: &Metadata) -> io::Result<Self> {
        if m.file_type().is_symlink() {
            return Ok(Self::symlink());
        }
        let allocation = m
            .blocks()
            .checked_mul(512)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or_else(|| invalid("invalid stat allocation"))?;
        Ok(Self {
            kind: if m.is_dir() {
                Kind::Dir
            } else if m.is_file() {
                Kind::File
            } else {
                Kind::Other
            },
            dev: m.dev(),
            ino: m.ino(),
            flags: m.st_flags(),
            links: u32::try_from(m.nlink()).map_err(|_| invalid("link count overflow"))?,
            allocation: Some(allocation),
            mount: 0,
        })
    }
}
#[derive(Clone, Debug)]
pub struct Node {
    pub parent: u32,
    pub name_len: u32,
    pub name_offset: u64,
    pub dev: u64,
    pub ino: u64,
    pub raw: u64,
    pub accounted: u64,
    pub subtree: u64,
    pub links: u32,
    pub kind: Kind,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counters {
    pub symlinks: u64,
    pub mounts: u64,
    pub firmlinks: u64,
    pub errors: u64,
    pub metadata_fallbacks: u64,
    pub root_fstats: u64,
    pub directory_fstats: u64,
    pub duplicate_dirs: u64,
}
#[derive(Clone, Debug)]
pub struct Map {
    pub root: PathBuf,
    pub nodes: Vec<Node>,
    pub names: Vec<u8>,
    pub counters: Counters,
    pub error_samples: Vec<String>,
}
impl Map {
    fn add(&mut self, parent: u32, name: &[u8], e: Entry) -> io::Result<u32> {
        let id = u32::try_from(self.nodes.len()).map_err(|_| invalid("arena exceeds u32 IDs"))?;
        let raw = e
            .allocation
            .ok_or_else(|| invalid("allocation not supplied"))?;
        let name_len = u32::try_from(name.len()).map_err(|_| invalid("basename too long"))?;
        self.nodes.push(Node {
            parent,
            name_len,
            name_offset: self.names.len() as u64,
            dev: e.dev,
            ino: e.ino,
            raw,
            accounted: raw,
            subtree: raw,
            links: e.links,
            kind: e.kind,
        });
        self.names.extend_from_slice(name);
        Ok(id)
    }
    pub fn basename(&self, id: usize) -> &[u8] {
        let n = &self.nodes[id];
        &self.names[n.name_offset as usize..n.name_offset as usize + n.name_len as usize]
    }
    pub fn relative_path(&self, mut id: usize) -> Vec<u8> {
        let mut ids = Vec::new();
        while id != 0 {
            ids.push(id);
            id = self.nodes[id].parent as usize;
        }
        let mut path = Vec::new();
        for id in ids.into_iter().rev() {
            if !path.is_empty() {
                path.push(b'/');
            }
            path.extend(self.basename(id));
        }
        path
    }
    fn path(&self, id: usize) -> PathBuf {
        self.root.join(OsStr::from_bytes(&self.relative_path(id)))
    }
    fn error(&mut self, path: &Path, error: impl std::fmt::Display) {
        self.counters.errors += 1;
        if self.error_samples.len() < 16 {
            self.error_samples
                .push(format!("{}\t{}", hex(path.as_os_str().as_bytes()), error));
        }
    }
    /// Only multiply-linked regular files need identity storage or path comparisons.
    /// Parent IDs precede children, so one reverse pass computes subtree totals.
    pub fn aggregate(&mut self) -> io::Result<()> {
        for n in &mut self.nodes {
            n.accounted = n.raw;
        }
        let mut owners: HashMap<(u64, u64), usize> = HashMap::new();
        for id in 0..self.nodes.len() {
            let n = &self.nodes[id];
            if n.kind != Kind::File || n.links < 2 {
                continue;
            }
            let key = (n.dev, n.ino);
            if let Some(&owner) = owners.get(&key) {
                if self.nodes[owner].raw != n.raw {
                    return Err(invalid("hardlink allocation changed during scan"));
                }
                if self.relative_path(id) < self.relative_path(owner) {
                    self.nodes[owner].accounted = 0;
                    owners.insert(key, id);
                } else {
                    self.nodes[id].accounted = 0;
                }
            } else {
                owners.insert(key, id);
            }
        }
        for n in &mut self.nodes {
            n.subtree = n.accounted;
        }
        for id in (1..self.nodes.len()).rev() {
            let parent = self.nodes[id].parent as usize;
            self.nodes[parent].subtree = self.nodes[parent]
                .subtree
                .checked_add(self.nodes[id].subtree)
                .ok_or_else(|| invalid("allocated total overflow"))?;
        }
        Ok(())
    }
    pub fn arena_bytes(&self) -> usize {
        self.nodes.capacity() * std::mem::size_of::<Node>() + self.names.capacity()
    }
    /// Opt-in only: raw relative paths encoded as hex, canonical byte ordering.
    pub fn canonical(&self) -> Vec<(Vec<u8>, u32, u64, u64, u64)> {
        let mut rows: Vec<_> = self
            .nodes
            .iter()
            .enumerate()
            .map(|(id, n)| {
                (
                    self.relative_path(id),
                    n.kind as u32,
                    n.raw,
                    n.accounted,
                    n.subtree,
                )
            })
            .collect();
        rows.sort_unstable_by(|a, b| a.0.cmp(&b.0));
        rows
    }
    /// O(N log limit), not a retained per-file path inventory.
    pub fn largest(&self, root_children: bool, limit: usize) -> Vec<usize> {
        let mut top = std::collections::BinaryHeap::new();
        for (id, n) in self.nodes.iter().enumerate().skip(1) {
            if (root_children && n.parent == 0) || (!root_children && n.kind == Kind::File) {
                top.push(std::cmp::Reverse((
                    if root_children { n.subtree } else { n.raw },
                    id,
                )));
                if top.len() > limit {
                    top.pop();
                }
            }
        }
        let mut ids: Vec<_> = top.into_iter().map(|v| v.0).collect();
        ids.sort_unstable_by(|a, b| b.cmp(a));
        ids.into_iter().map(|v| v.1).collect()
    }
}
#[derive(Clone, Copy, Debug)]
pub enum Method {
    Bulk,
    Stat,
}
impl Method {
    pub fn name(self) -> &'static str {
        match self {
            Self::Bulk => "bulk",
            Self::Stat => "stat",
        }
    }
}
pub struct Scan {
    pub map: Map,
    pub scan_time: Duration,
    pub aggregation_time: Duration,
}
struct State {
    map: Map,
    pending: VecDeque<u32>,
    active: usize,
    seen_dirs: HashSet<(u64, u64)>,
    excluded_snapshot: Option<(u64, u64)>,
}

fn open_directory(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY | libc::O_CLOEXEC)
        .open(path)
}

pub fn scan(root: &Path, method: Method, workers: usize) -> io::Result<Scan> {
    scan_excluding_snapshot(root, method, workers, None)
}

// The caller must keep the snapshot open throughout collection to pin its identity.
fn scan_excluding_snapshot(
    root: &Path,
    method: Method,
    workers: usize,
    excluded_snapshot: Option<(u64, u64)>,
) -> io::Result<Scan> {
    if ![1, 2, 4, 8].contains(&workers) {
        return Err(invalid("workers must be 1, 2, 4, or 8"));
    }
    if !root.is_absolute()
        || root
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(invalid(
            "root must be absolute without . or ..; symlink components are rejected",
        ));
    }
    let start = Instant::now();
    let root_file = open_directory(root)?;
    let root_entry = Entry::metadata(&root_file.metadata()?)?;
    if root_entry.flags & native::SF_FIRMLINK != 0 {
        return Err(invalid("root is a firmlink"));
    }
    let device = root_entry.dev;
    let seen_dirs = HashSet::from([(device, root_entry.ino)]);
    let mounts = native::mount_paths()?;
    let mut map = Map {
        root: root.to_path_buf(),
        nodes: Vec::new(),
        names: Vec::new(),
        counters: Counters::default(),
        error_samples: Vec::new(),
    };
    map.counters.root_fstats = 1;
    map.add(0, b"", root_entry)?;
    let shared = (
        Mutex::new(State {
            map,
            pending: VecDeque::from([0]),
            active: 0,
            seen_dirs,
            excluded_snapshot,
        }),
        Condvar::new(),
    );
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let shared = &shared;
            let mounts = &mounts;
            scope.spawn(move || {
                loop {
                    let (id, path, expected) = {
                        let mut state = shared.0.lock().unwrap();
                        loop {
                            if let Some(id) = state.pending.pop_front() {
                                state.active += 1;
                                let n = &state.map.nodes[id as usize];
                                break (id, state.map.path(id as usize), (n.dev, n.ino));
                            }
                            if state.active == 0 {
                                return;
                            }
                            state = shared.1.wait(state).unwrap();
                        }
                    };
                    let result = (|| {
                        let dir = open_directory(&path)?;
                        let meta = dir.metadata()?;
                        {
                            shared.0.lock().unwrap().map.counters.directory_fstats += 1;
                        }
                        if (meta.dev(), meta.ino()) != expected {
                            return Err(invalid("directory identity changed before open"));
                        }
                        let mut batch = Vec::with_capacity(256);
                        let mut visit = |record: native::BulkRecord| {
                            batch.push(record);
                            if batch.len() == 256 {
                                merge(shared, mounts, device, id, &path, &mut batch);
                            }
                        };
                        let result = match method {
                            Method::Bulk => native::enumerate(&dir, &mut visit),
                            Method::Stat => (|| {
                                for child in fs::read_dir(&path)? {
                                    match child {
                                        Ok(child) => visit(native::BulkRecord {
                                            name: child.file_name().as_bytes().to_vec(),
                                            result: fs::symlink_metadata(child.path())
                                                .and_then(|m| Entry::metadata(&m)),
                                        }),
                                        Err(error) => {
                                            shared.0.lock().unwrap().map.error(&path, error)
                                        }
                                    }
                                }
                                Ok(())
                            })(),
                        };
                        merge(shared, mounts, device, id, &path, &mut batch);
                        result
                    })();
                    let mut state = shared.0.lock().unwrap();
                    if let Err(error) = result {
                        state.map.error(&path, error);
                    }
                    state.active -= 1;
                    shared.1.notify_all();
                }
            });
        }
    });
    let mut map = shared.0.into_inner().unwrap().map;
    let scan_time = start.elapsed();
    let aggregation = Instant::now();
    map.aggregate()?;
    Ok(Scan {
        map,
        scan_time,
        aggregation_time: aggregation.elapsed(),
    })
}

fn merge(
    shared: &(Mutex<State>, Condvar),
    mounts: &HashSet<PathBuf>,
    device: u64,
    parent: u32,
    directory: &Path,
    batch: &mut Vec<native::BulkRecord>,
) {
    // Filesystem fallback calls occur outside the arena lock. At most 256 entries
    // per worker are staged; pending work is compact directory IDs, never paths.
    let mut fallbacks = 0;
    for record in batch.iter_mut() {
        if let Ok(e) = &mut record.result
            && e.kind == Kind::Dir
            && e.allocation.is_none()
            && e.dev == device
            && e.mount == 0
            && e.flags & native::SF_FIRMLINK == 0
            && !mounts.contains(&directory.join(OsStr::from_bytes(&record.name)))
        {
            fallbacks += 1;
            record.result = fs::symlink_metadata(directory.join(OsStr::from_bytes(&record.name)))
                .and_then(|m| {
                    if !m.is_dir() || (m.dev(), m.ino()) != (e.dev, e.ino) {
                        return Err(invalid("directory changed during allocation fallback"));
                    }
                    e.allocation = Entry::metadata(&m)?.allocation;
                    Ok(Entry {
                        kind: e.kind,
                        dev: e.dev,
                        ino: e.ino,
                        flags: e.flags,
                        links: e.links,
                        allocation: e.allocation,
                        mount: e.mount,
                    })
                });
        }
    }
    let mut state = shared.0.lock().unwrap();
    state.map.counters.metadata_fallbacks += fallbacks;
    for record in batch.drain(..) {
        let path = directory.join(OsStr::from_bytes(&record.name));
        let e = match record.result {
            Ok(e) => e,
            Err(error) => {
                state.map.error(&path, error);
                continue;
            }
        };
        if e.kind == Kind::Symlink {
            state.map.counters.symlinks += 1;
            continue;
        }
        if e.flags & native::SF_FIRMLINK != 0 {
            state.map.counters.firmlinks += 1;
            continue;
        }
        if e.dev != device || e.mount != 0 || mounts.contains(&path) {
            state.map.counters.mounts += 1;
            continue;
        }
        if e.kind == Kind::File && state.excluded_snapshot == Some((e.dev, e.ino)) {
            continue;
        }
        let is_dir = e.kind == Kind::Dir;
        if is_dir && !state.seen_dirs.insert((e.dev, e.ino)) {
            state.map.counters.duplicate_dirs += 1;
            state
                .map
                .error(&path, "duplicate directory identity; not traversed");
            continue;
        }
        match state.map.add(parent, &record.name, e) {
            Ok(id) if is_dir => state.pending.push_back(id),
            Ok(_) => {}
            Err(error) => state.map.error(&path, error),
        }
    }
    shared.1.notify_all();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_identity_exclusion_precedes_accounting_in_both_collectors() {
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                fs::remove_dir_all(&self.0).unwrap();
            }
        }
        let root = PathBuf::from(format!(
            "/private/tmp/disk-inventory-exclusion-test-{}",
            std::process::id()
        ));
        fs::create_dir(&root).unwrap();
        let _fixture = Fixture(root.clone());
        fs::create_dir(root.join("nested")).unwrap();
        fs::write(root.join("map.dmap"), vec![3; 65537]).unwrap();
        fs::hard_link(root.join("map.dmap"), root.join("nested/alias")).unwrap();
        fs::write(root.join("other.bin"), vec![4; 32769]).unwrap();
        let file = File::open(root.join("map.dmap")).unwrap();
        let metadata = file.metadata().unwrap();
        let identity = (metadata.dev(), metadata.ino());
        for method in [Method::Bulk, Method::Stat] {
            for workers in [1, 4] {
                let full = scan(&root, method, workers).unwrap().map;
                let filtered = scan_excluding_snapshot(&root, method, workers, Some(identity))
                    .unwrap()
                    .map;
                assert_eq!(filtered.counters.errors, 0);
                assert_eq!(filtered.nodes.len(), 3);
                assert!(!filtered.nodes.iter().any(|n| (n.dev, n.ino) == identity));
                assert_eq!(
                    filtered
                        .canonical()
                        .iter()
                        .map(|row| row.0.clone())
                        .collect::<Vec<_>>(),
                    [b"".to_vec(), b"nested".to_vec(), b"other.bin".to_vec()]
                );
                assert!(metadata.blocks() > 0);
                assert_eq!(
                    full.nodes[0].subtree - filtered.nodes[0].subtree,
                    metadata.blocks() * 512
                );
                let directory = &full.nodes[0];
                let unchanged = scan_excluding_snapshot(
                    &root,
                    method,
                    workers,
                    Some((directory.dev, directory.ino)),
                )
                .unwrap()
                .map;
                assert_eq!(unchanged.canonical(), full.canonical());
            }
        }
        drop(file);
    }
}
