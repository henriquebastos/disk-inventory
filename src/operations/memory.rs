//! Stateful, native-free adapter for tests and later GUI scenarios. No native fallback.
use super::*;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
};

#[derive(Debug)]
pub struct MemoryPin {
    identity: Identity,
    pins: Arc<Mutex<BTreeMap<Identity, usize>>>,
}
impl Drop for MemoryPin {
    fn drop(&mut self) {
        let mut pins = self.pins.lock().unwrap();
        let count = pins.get_mut(&self.identity).unwrap();
        *count -= 1;
        if *count == 0 {
            pins.remove(&self.identity);
        }
    }
}

#[derive(Clone, Debug)]
pub enum TrashBehavior {
    MoveTo(PathBuf),
    Fail(String),
    /// Performs the move but simulates Foundation returning no usable URL.
    MissingDestination(PathBuf),
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MemoryCalls {
    pub metadata: usize,
    pub directories: usize,
    pub trash: usize,
    pub remove: usize,
}
#[derive(Debug)]
pub struct MemoryFileSystem {
    entries: BTreeMap<PathBuf, LiveMetadata>,
    aliases: BTreeMap<PathBuf, PathBuf>,
    snapshot: Option<Identity>,
    pins: Arc<Mutex<BTreeMap<Identity, usize>>>,
    pub unreadable: BTreeSet<PathBuf>,
    pub metadata_errors: BTreeSet<PathBuf>,
    pub trash_behavior: TrashBehavior,
    pub unknown_scope: bool,
    /// Fail after exactly this many unlinks (0 guarantees no changes).
    pub remove_failure_after: Option<usize>,
    /// Inject a reconciliation enumeration failure after a partial removal.
    pub unreadable_after_partial: bool,
    pub calls: MemoryCalls,
}
impl Default for MemoryFileSystem {
    fn default() -> Self {
        Self {
            entries: BTreeMap::new(),
            aliases: BTreeMap::new(),
            snapshot: None,
            pins: Arc::default(),
            unreadable: BTreeSet::new(),
            metadata_errors: BTreeSet::new(),
            trash_behavior: TrashBehavior::Fail("no fake Trash destination configured".into()),
            unknown_scope: false,
            remove_failure_after: None,
            unreadable_after_partial: false,
            calls: MemoryCalls::default(),
        }
    }
}
impl MemoryFileSystem {
    pub fn pinned_count(&self) -> usize {
        self.pins.lock().unwrap().values().sum()
    }
    pub fn insert(&mut self, path: impl Into<PathBuf>, metadata: LiveMetadata) {
        // Callers supply realistic link counts; a declared hardlink shares inode
        // metadata with all existing aliases. Ordinary singleton fixture insertion
        // stays O(log N), while alias edits intentionally favor simple fake code.
        if metadata.kind == Kind::File && metadata.links > 1 {
            for existing in self.entries.values_mut() {
                if existing.kind == Kind::File && existing.identity == metadata.identity {
                    *existing = metadata.clone();
                }
            }
        }
        self.entries.insert(self.canonical(&path.into()), metadata);
    }
    pub fn erase(&mut self, path: &Path) {
        let path = self.canonical(path);
        if let Some(m) = self.entries.remove(&path)
            && m.kind == Kind::File
            && m.links > 1
        {
            for existing in self.entries.values_mut() {
                if existing.identity == m.identity && existing.kind == Kind::File {
                    existing.links = existing.links.saturating_sub(1);
                }
            }
        }
    }
    pub fn get(&self, path: &Path) -> Option<&LiveMetadata> {
        self.entries.get(&self.canonical(path))
    }
    pub fn pin_snapshot(&mut self, identity: Identity) {
        self.snapshot = Some(identity);
    }
    /// Models an alternate namespace spelling of the same directory, not a symlink.
    pub fn add_directory_alias(&mut self, alias: PathBuf, original: PathBuf) {
        self.aliases.insert(alias, original);
    }
    fn canonical(&self, path: &Path) -> PathBuf {
        for (alias, original) in &self.aliases {
            if let Ok(rest) = path.strip_prefix(alias) {
                return original.join(rest);
            }
        }
        path.to_path_buf()
    }
    pub fn move_entry(&mut self, from: &Path, to: &Path) -> io::Result<()> {
        let from = self.canonical(from);
        let to = self.canonical(to);
        if !self.entries.contains_key(&from)
            || self.entries.contains_key(&to)
            || to.starts_with(&from)
        {
            return Err(invalid("invalid fake move"));
        }
        if !self
            .entries
            .get(
                to.parent()
                    .ok_or_else(|| invalid("destination has no parent"))?,
            )
            .is_some_and(|m| m.kind == Kind::Dir)
        {
            return Err(invalid("fake destination parent missing"));
        }
        let moving: Vec<_> = self
            .entries
            .keys()
            .filter(|p| p.starts_with(&from))
            .cloned()
            .collect();
        for path in moving {
            let metadata = self.entries.remove(&path).unwrap();
            self.entries
                .insert(to.join(path.strip_prefix(&from).unwrap()), metadata);
        }
        Ok(())
    }
    fn check(&mut self, target: &Target) -> io::Result<()> {
        let m = self.metadata(&target.path)?;
        if m.identity != target.identity || m.kind != target.kind || m.kind == Kind::Symlink {
            return Err(invalid("fake target changed"));
        }
        Ok(())
    }
    fn protected_below(&self, path: &Path) -> bool {
        self.entries
            .iter()
            .any(|(p, m)| p.starts_with(path) && Some(m.identity) == self.snapshot)
    }
}
impl FileSystem for MemoryFileSystem {
    type Pin = MemoryPin;
    fn pin(&mut self, target: &Target) -> io::Result<Self::Pin> {
        self.check(target)?;
        *self
            .pins
            .lock()
            .unwrap()
            .entry(target.identity)
            .or_default() += 1;
        Ok(MemoryPin {
            identity: target.identity,
            pins: self.pins.clone(),
        })
    }
    fn snapshot_identity(&self) -> Option<Identity> {
        self.snapshot
    }
    fn metadata(&mut self, path: &Path) -> io::Result<LiveMetadata> {
        self.calls.metadata += 1;
        let path = self.canonical(path);
        if self.metadata_errors.contains(&path) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "injected metadata failure",
            ));
        }
        for parent in path.ancestors().skip(1) {
            if self
                .entries
                .get(parent)
                .is_some_and(|m| m.kind == Kind::Symlink)
            {
                return Err(invalid("symlink in fake ancestry"));
            }
        }
        self.entries
            .get(&path)
            .cloned()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "fake target missing"))
    }
    fn read_directory(&mut self, target: &Target) -> io::Result<Vec<DirectoryEntry>> {
        self.calls.directories += 1;
        self.check(target)?;
        let path = self.canonical(&target.path);
        if self.unreadable.contains(&path) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "injected enumeration failure",
            ));
        }
        if target.kind != Kind::Dir {
            return Err(invalid("not a directory"));
        }
        Ok(self
            .entries
            .iter()
            .filter(|(p, _)| p.parent() == Some(path.as_path()))
            .map(|(p, m)| DirectoryEntry {
                name: p.file_name().unwrap().as_bytes().to_vec(),
                metadata: ScanMetadata::from(m),
            })
            .collect())
    }
    fn trash(&mut self, target: &Target, pin: &Self::Pin) -> Mutation {
        if pin.identity != target.identity {
            return Mutation::Failed("wrong pinned target".into());
        }
        self.calls.trash += 1;
        if let Err(e) = self.check(target) {
            return Mutation::Failed(e.to_string());
        }
        if self.protected_below(&self.canonical(&target.path)) {
            return Mutation::Failed("active snapshot protected".into());
        }
        let (destination, missing) = match self.trash_behavior.clone() {
            TrashBehavior::MoveTo(p) => (p, false),
            TrashBehavior::MissingDestination(p) => (p, true),
            TrashBehavior::Fail(e) => return Mutation::Failed(e),
        };
        match self.move_entry(&target.path, &destination) {
            Ok(()) if missing => Mutation::Indeterminate("fake missing resulting URL".into()),
            Ok(()) => Mutation::Trashed { destination },
            Err(e) => Mutation::Failed(e.to_string()),
        }
    }
    fn remove(&mut self, target: &Target, pin: &Self::Pin) -> Mutation {
        if pin.identity != target.identity {
            return Mutation::Failed("wrong pinned target".into());
        }
        self.calls.remove += 1;
        if let Err(e) = self.check(target) {
            return Mutation::Failed(e.to_string());
        }
        let path = self.canonical(&target.path);
        if self.protected_below(&path) {
            return Mutation::Failed("active snapshot protected".into());
        }
        let mut removed: Vec<_> = self
            .entries
            .keys()
            .filter(|p| p.starts_with(&path))
            .cloned()
            .collect();
        removed.sort_by_key(|p| std::cmp::Reverse(p.components().count()));
        for (done, p) in removed.into_iter().enumerate() {
            if self.remove_failure_after == Some(done) {
                if done != 0 && self.unreadable_after_partial {
                    self.unreadable.insert(path.clone());
                }
                return if done == 0 {
                    Mutation::Failed("injected unlink failure".into())
                } else {
                    Mutation::Partial("injected partial removal".into())
                };
            }
            self.erase(&p);
        }
        Mutation::Removed
    }
    fn classify_destination(&mut self, path: &Path, root: Identity) -> DestinationScope {
        if self.unknown_scope {
            return DestinationScope::Unknown;
        }
        let path = self.canonical(path);
        let mut parts = vec![
            path.file_name()
                .map(|n| n.as_bytes().to_vec())
                .unwrap_or_default(),
        ];
        for parent in path.ancestors().skip(1) {
            match self.metadata(parent) {
                Ok(m) if m.kind == Kind::Dir && m.identity == root => {
                    parts.reverse();
                    return DestinationScope::Inside(parts.join(&b'/'));
                }
                Ok(m) if m.kind == Kind::Dir => {}
                _ => return DestinationScope::Unknown,
            }
            if let Some(name) = parent.file_name() {
                parts.push(name.as_bytes().to_vec());
            }
        }
        DestinationScope::Outside
    }
}
