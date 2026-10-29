//! Stateful, native-free adapter for tests and later GUI scenarios. No native fallback.
use super::*;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Condvar, Mutex},
    time::Duration,
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
    pub protection_checks: usize,
    pub trash: usize,
    pub remove: usize,
}
/// A fixture operation stage that `OperationStages` can delay or hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// Each target-level check, at prepare and at execute.
    Check,
    /// Before the fake Trash move.
    Trash,
    /// Once, after `OperationStages::hold_removal_after` removed entries.
    Remove,
    /// The first metadata request after a mutation: the inventory update.
    Update,
}
impl Stage {
    pub fn name(self) -> &'static str {
        match self {
            Self::Check => "check",
            Self::Trash => "trash",
            Self::Remove => "remove",
            Self::Update => "update",
        }
    }
}
/// Holds fixture operations at a stage until a test releases them, so tests need no sleeps.
#[derive(Debug, Default)]
pub struct StageGate {
    state: Mutex<GateState>,
    changed: Condvar,
}
#[derive(Debug, Default)]
struct GateState {
    held: Option<Stage>,
    releases: usize,
}
impl StageGate {
    fn hold(&self, stage: Stage) {
        let mut state = self.state.lock().unwrap();
        state.held = Some(stage);
        self.changed.notify_all();
        while state.releases == 0 {
            state = self.changed.wait(state).unwrap();
        }
        state.releases -= 1;
    }
    /// Waits until an operation is held, then returns its stage; None after `timeout`.
    pub fn wait_for_held(&self, timeout: Duration) -> Option<Stage> {
        let state = self.state.lock().unwrap();
        let (state, _) = self
            .changed
            .wait_timeout_while(state, timeout, |s| s.held.is_none())
            .unwrap();
        state.held
    }
    /// Lets the held operation continue to its next stage.
    pub fn release(&self) {
        let mut state = self.state.lock().unwrap();
        state.held = None;
        state.releases += 1;
        self.changed.notify_all();
    }
}
/// Explicit fixture-only operation latency and gate; none by default.
#[derive(Clone, Debug, Default)]
pub struct OperationStages {
    pub check: Duration,
    pub trash: Duration,
    pub per_removal: Duration,
    pub update: Duration,
    pub gate: Option<Arc<StageGate>>,
    pub hold_removal_after: u64,
}
#[derive(Debug)]
pub struct MemoryFileSystem {
    entries: BTreeMap<PathBuf, LiveMetadata>,
    aliases: BTreeMap<PathBuf, PathBuf>,
    snapshot: Option<Identity>,
    pins: Arc<Mutex<BTreeMap<Identity, usize>>>,
    pub unreadable: BTreeSet<PathBuf>,
    pub metadata_errors: BTreeSet<PathBuf>,
    /// Explicit fixture-only latency; empty by default. Never used by the native adapter.
    pub metadata_delays: BTreeMap<PathBuf, std::time::Duration>,
    pub trash_behavior: TrashBehavior,
    pub unknown_scope: bool,
    pub stages: OperationStages,
    /// Entries removal skips, with their reason, like a locked file.
    pub remove_skips: BTreeMap<PathBuf, String>,
    /// An error that ends the removal walk after exactly this many unlinks (0 guarantees
    /// no changes).
    pub remove_failure_after: Option<u64>,
    /// Inject a reconciliation enumeration failure after a partial removal.
    pub unreadable_after_partial: bool,
    pub calls: MemoryCalls,
    mutated: bool,
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
            metadata_delays: BTreeMap::new(),
            trash_behavior: TrashBehavior::Fail("no fake Trash destination configured".into()),
            unknown_scope: false,
            stages: OperationStages::default(),
            remove_skips: BTreeMap::new(),
            remove_failure_after: None,
            unreadable_after_partial: false,
            calls: MemoryCalls::default(),
            mutated: false,
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
    /// The entry and its descendants: they follow it in path order.
    fn subtree(&self, path: &Path) -> impl Iterator<Item = (&PathBuf, &LiveMetadata)> {
        self.entries
            .range(path.to_path_buf()..)
            .take_while(move |(p, _)| p.starts_with(path))
    }
    fn protected_below(&self, path: &Path) -> bool {
        self.subtree(path)
            .any(|(_, m)| Some(m.identity) == self.snapshot)
    }
    fn pause(&self, stage: Stage) {
        let delay = match stage {
            Stage::Check => self.stages.check,
            Stage::Trash => self.stages.trash,
            Stage::Remove => Duration::ZERO,
            Stage::Update => self.stages.update,
        };
        if !delay.is_zero() {
            std::thread::sleep(delay);
        }
        if let Some(gate) = &self.stages.gate {
            gate.hold(stage);
        }
    }
    /// The fake of the native removal walk: the same skip and stop classes over the map.
    fn remove_walk(
        &mut self,
        path: &Path,
        expected: Identity,
        kind: Kind,
        device: u64,
        walk: &mut RemovalWalk,
    ) -> io::Result<bool> {
        walk.check_stop()?;
        let Some(current) = self.entries.get(path).cloned() else {
            return Ok(true);
        };
        if current.identity != expected || current.kind != kind {
            return Ok(walk.skip(path, "changed since the scan"));
        }
        if Some(expected) == self.snapshot
            || expected.device != device
            || current.mount
            || current.flags & crate::native::SF_FIRMLINK != 0
        {
            return Ok(walk.skip(path, "protected (active snapshot, mount or firmlink)"));
        }
        if let Some(reason) = self.remove_skips.get(path).cloned() {
            return Ok(walk.skip(path, &reason));
        }
        if kind == Kind::Dir {
            if self.unreadable.contains(path) {
                return Ok(walk.skip(path, "permission denied"));
            }
            let children: Vec<_> = self
                .subtree(path)
                .filter(|(p, _)| p.parent() == Some(path))
                .map(|(p, m)| (p.clone(), m.identity, m.kind))
                .collect();
            let mut kept = false;
            for (child, identity, kind) in children {
                kept |= !self.remove_walk(&child, identity, kind, device, walk)?;
            }
            if kept {
                return Ok(false);
            }
        }
        if self.remove_failure_after == Some(walk.removed_count()) {
            return Err(invalid("injected unlink failure"));
        }
        if !self.stages.per_removal.is_zero() {
            std::thread::sleep(self.stages.per_removal);
        }
        self.erase(path);
        walk.removed();
        if self.stages.gate.is_some() && walk.removed_count() == self.stages.hold_removal_after {
            self.pause(Stage::Remove);
        }
        Ok(true)
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
        if std::mem::take(&mut self.mutated) {
            self.pause(Stage::Update);
        }
        let path = self.canonical(path);
        if let Some(delay) = self.metadata_delays.get(&path) {
            std::thread::sleep(*delay);
        }
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
    fn refuse_protected_within(&mut self, target: &Target) -> io::Result<()> {
        self.calls.protection_checks += 1;
        self.pause(Stage::Check);
        let path = self.canonical(&target.path);
        for (_, m) in self.subtree(&path) {
            if Some(m.identity) == self.snapshot {
                return Err(invalid("the active snapshot is inside the target"));
            }
            if m.mount
                || m.flags & crate::native::SF_FIRMLINK != 0
                || m.identity.device != target.identity.device
            {
                return Err(invalid("a mount or firmlink is inside the target"));
            }
        }
        Ok(())
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
        self.pause(Stage::Trash);
        let moved = self.move_entry(&target.path, &destination);
        self.mutated = moved.is_ok();
        match moved {
            Ok(()) if missing => Mutation::Indeterminate("fake missing resulting URL".into()),
            Ok(()) => Mutation::Trashed { destination },
            Err(e) => Mutation::Failed(e.to_string()),
        }
    }
    fn remove(
        &mut self,
        target: &Target,
        pin: &Self::Pin,
        control: Option<&ScanControl>,
    ) -> Mutation {
        if pin.identity != target.identity {
            return Mutation::Failed("wrong pinned target".into());
        }
        self.calls.remove += 1;
        if let Err(e) = self.check(target) {
            return Mutation::Failed(e.to_string());
        }
        let path = self.canonical(&target.path);
        let mut walk = RemovalWalk::new(control);
        let result = self.remove_walk(
            &path,
            target.identity,
            target.kind,
            target.identity.device,
            &mut walk,
        );
        self.mutated = walk.removed_count() != 0;
        if result.is_err() && self.mutated && self.unreadable_after_partial {
            self.unreadable.insert(path);
        }
        walk.outcome(result)
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
