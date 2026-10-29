//! Explicit live operations over an indexed inventory. Run I/O on a worker thread.
//! Saved reads stay available offline; confirmations are single-use capabilities.
mod index;
/// The fake filesystem with stage gates: for tests and the bridge fixture mode only.
#[cfg(any(test, feature = "bridge"))]
pub mod memory;
pub mod native;

use crate::{
    Kind,
    explorer::{EntryHandle, Explorer},
    invalid,
    scan_control::{ScanControl, ScanPhase},
};
use std::{
    collections::{BTreeSet, HashMap, HashSet},
    ffi::OsStr,
    io,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Identity {
    pub device: u64,
    pub inode: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveMetadata {
    pub identity: Identity,
    pub kind: Kind,
    pub allocated_bytes: u64,
    pub logical_bytes: u64,
    pub links: u32,
    pub mode: u32,
    pub modified_seconds: i64,
    pub modified_nanoseconds: i64,
    pub created_seconds: i64,
    pub flags: u32,
    pub mount: bool,
}
/// Collection/accounting fields only; inspector timestamps, mode and logical size
/// remain in LiveMetadata and are never fabricated by bulk enumeration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanMetadata {
    pub identity: Identity,
    pub kind: Kind,
    pub allocated_bytes: u64,
    pub links: u32,
    pub flags: u32,
    pub mount: bool,
}
impl From<&LiveMetadata> for ScanMetadata {
    fn from(m: &LiveMetadata) -> Self {
        Self {
            identity: m.identity,
            kind: m.kind,
            allocated_bytes: m.allocated_bytes,
            links: m.links,
            flags: m.flags,
            mount: m.mount,
        }
    }
}
#[derive(Clone, Debug)]
pub struct DirectoryEntry {
    pub name: Vec<u8>,
    pub metadata: ScanMetadata,
}
#[derive(Clone, Debug)]
pub struct Target {
    pub path: PathBuf,
    pub identity: Identity,
    pub kind: Kind,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DestinationScope {
    /// Relative raw path, derived from directory identity ancestry, never a prefix test.
    Inside(Vec<u8>),
    Outside,
    Unknown,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mutation {
    Removed,
    /// The removal walk finished and removed at least one entry, but entries it could not
    /// or must not remove remain, with their folders.
    RemovedWithSkips(Removal),
    Trashed {
        destination: PathBuf,
    },
    /// No usable destination, or failure after mutation may have started.
    Indeterminate(String),
    /// The removal walk ended early after removing at least one entry: by Stop
    /// (`stopped`) or by an error that ends the walk (`message`).
    Partial {
        message: String,
        stopped: bool,
        removal: Removal,
    },
    /// Adapter guarantees no mutation took place.
    Failed(String),
}
/// The counts of one permanent removal walk. `skipped` counts entries refused or failed
/// for their own reason; a folder kept only because it still holds a skipped entry is not
/// counted. `reasons` keeps the first `Removal::REASON_LIMIT` of them as "path: reason",
/// for display only.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Removal {
    pub removed: u64,
    pub skipped: u64,
    pub reasons: Vec<String>,
}
impl Removal {
    pub const REASON_LIMIT: usize = 16;
}
/// One removal walk's counts, its Stop checks and its live progress: `items_examined`
/// counts each removed entry, an atomic add beside each unlink.
pub(crate) struct RemovalWalk<'a> {
    control: Option<&'a ScanControl>,
    removal: Removal,
}
impl<'a> RemovalWalk<'a> {
    pub(crate) fn new(control: Option<&'a ScanControl>) -> Self {
        Self {
            control,
            removal: Removal::default(),
        }
    }
    /// Stop is checked before each entry.
    pub(crate) fn check_stop(&self) -> io::Result<()> {
        crate::scan_control::check(self.control)
    }
    pub(crate) fn removed(&mut self) {
        self.removal.removed += 1;
        if let Some(control) = self.control {
            control.examined(1);
        }
    }
    #[cfg(any(test, feature = "bridge"))]
    pub(crate) fn removed_count(&self) -> u64 {
        self.removal.removed
    }
    /// Counts a skipped entry; the walk continues. Returns false: the entry stays.
    pub(crate) fn skip(&mut self, path: &Path, reason: &str) -> bool {
        self.removal.skipped += 1;
        if self.removal.reasons.len() < Removal::REASON_LIMIT {
            self.removal
                .reasons
                .push(format!("{}: {reason}", path.display()));
        }
        false
    }
    /// `walk` is true when the target is gone; an error ended the walk.
    pub(crate) fn outcome(self, walk: io::Result<bool>) -> Mutation {
        let removal = self.removal;
        match walk {
            Ok(true) => Mutation::Removed,
            Ok(false) if removal.removed == 0 => Mutation::Failed(format!(
                "nothing was deleted; skipped {}",
                removal.reasons.join("; ")
            )),
            Ok(false) => Mutation::RemovedWithSkips(removal),
            Err(e) if removal.removed == 0 => Mutation::Failed(e.to_string()),
            Err(e) => {
                let stopped = e
                    .get_ref()
                    .is_some_and(|e| e.is::<crate::scan_control::ScanCancelled>());
                Mutation::Partial {
                    message: if stopped {
                        "deletion stopped".into()
                    } else {
                        e.to_string()
                    },
                    stopped,
                    removal,
                }
            }
        }
    }
}
/// Narrow filesystem seam. Implementations must not follow symlinks in target ancestry,
/// must validate expected identity immediately before mutation, and must protect the
/// pinned snapshot. Enumeration is complete-or-error (never an error-shaped empty list).
/// No implementation may fall back from Trash to removal.
pub trait FileSystem {
    type Pin;
    /// Retain this live inode (metadata-only) until the confirmation is consumed/dropped.
    fn pin(&mut self, target: &Target) -> io::Result<Self::Pin>;
    fn snapshot_identity(&self) -> Option<Identity>;
    fn metadata(&mut self, path: &Path) -> io::Result<LiveMetadata>;
    fn read_directory(&mut self, target: &Target) -> io::Result<Vec<DirectoryEntry>>;
    /// Errors when the target is a mount point, or the active snapshot, a mount or a
    /// firmlink endpoint lies below it. It never lists the target's subtree, so its cost
    /// does not depend on the subtree's size.
    fn refuse_protected_within(&mut self, target: &Target) -> io::Result<()>;
    fn trash(&mut self, target: &Target, pin: &Self::Pin) -> Mutation;
    /// One walk that removes the target and its contents. It skips and reports what it
    /// cannot or must not remove, and checks Stop between entries.
    fn remove(
        &mut self,
        target: &Target,
        pin: &Self::Pin,
        control: Option<&ScanControl>,
    ) -> Mutation;
    fn classify_destination(&mut self, path: &Path, root: Identity) -> DestinationScope;
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Trash,
    PermanentlyDelete,
}
/// Private fields prevent manufacture; execute consumes it, and checks the current path.
#[derive(Debug)]
pub struct Confirmation<P> {
    handle: EntryHandle,
    action: Action,
    target: Target,
    pin: P,
    metadata: LiveMetadata,
}
impl<P> Confirmation<P> {
    /// Freshly observed after pinning; not a claim of unchanged historical identity.
    pub fn metadata(&self) -> &LiveMetadata {
        &self.metadata
    }
    pub fn handle(&self) -> EntryHandle {
        self.handle
    }
    pub fn action(&self) -> Action {
        self.action
    }
    pub fn path(&self) -> &Path {
        &self.target.path
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SessionState {
    pub dirty: bool,
    pub stale: bool,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UpdateWork {
    pub nodes_examined: usize,
    pub identity_comparisons: usize,
    /// Group visits, including baseline capture and all propagation/attribution passes.
    pub identity_members: usize,
    pub ancestor_updates: usize,
    pub child_ids_copied: usize,
    pub child_ids_sorted: usize,
    pub directories_read: usize,
}
#[derive(Debug)]
pub struct UpdateReport {
    pub state: SessionState,
    pub work: UpdateWork,
    pub issues: Vec<String>,
}
#[derive(Debug)]
pub struct OperationReport {
    pub mutation: Mutation,
    pub scope: Option<DestinationScope>,
    pub update: UpdateReport,
}
/// Owns one compact arena, one identity index and one adapter. No implicit save.
pub struct OperationSession<F: FileSystem> {
    explorer: Explorer,
    filesystem: F,
    identities: index::IdentityIndex,
    state: SessionState,
    work: UpdateWork,
    groups: BTreeSet<Identity>,
    observations: HashMap<Identity, index::FileObservation>,
    baselines: HashMap<Identity, Option<u64>>,
    unresolved_groups: HashSet<Identity>,
    survivor_groups: HashSet<Identity>,
    sort: HashSet<u32>,
    issues: Vec<String>,
    /// Live reads of a controlled refresh, present only while it applies them.
    prefetched: Option<index::LiveSubtree>,
}
impl<F: FileSystem> OperationSession<F> {
    /// Builds the identity index once, without consulting any source path.
    pub fn new(explorer: Explorer, filesystem: F) -> Self {
        let identities = index::IdentityIndex::new(&explorer);
        let stale = explorer.is_partial();
        Self {
            explorer,
            filesystem,
            identities,
            state: SessionState {
                dirty: false,
                stale,
            },
            work: UpdateWork::default(),
            groups: BTreeSet::new(),
            observations: HashMap::new(),
            baselines: HashMap::new(),
            unresolved_groups: HashSet::new(),
            survivor_groups: HashSet::new(),
            sort: HashSet::new(),
            issues: Vec::new(),
            prefetched: None,
        }
    }
    pub fn explorer(&self) -> &Explorer {
        &self.explorer
    }
    pub fn state(&self) -> SessionState {
        self.state
    }
    /// Exposed for explicit fixture setup/fault injection; never creates a native fallback.
    pub fn filesystem_mut(&mut self) -> &mut F {
        &mut self.filesystem
    }
    pub fn identity_index_bytes(&self) -> usize {
        self.identities.base_bytes()
    }
    fn target(&self, id: u32) -> Target {
        let node = &self.explorer.map.nodes[id as usize];
        Target {
            path: self.explorer.root().join(OsStr::from_bytes(
                &self.explorer.map.relative_path(id as usize),
            )),
            identity: index::identity(node),
            kind: node.kind,
        }
    }
    fn validate(&mut self, target: &Target) -> io::Result<LiveMetadata> {
        let m = self.filesystem.metadata(&target.path)?;
        if m.allocated_bytes > i64::MAX as u64 {
            return Err(invalid("invalid live allocation"));
        }
        if m.identity != target.identity || m.kind != target.kind || m.kind == Kind::Symlink {
            return Err(invalid("target missing, replaced or symlink-swapped"));
        }
        Ok(m)
    }
    /// Exactly one targeted metadata request; failure never changes saved accounting.
    pub fn live_metadata(&mut self, handle: EntryHandle) -> io::Result<LiveMetadata> {
        let id = self.explorer.resolve(handle)?;
        self.validate(&self.target(id))
    }
    /// The target-level checks of prepare and execute. They read the root, the target and
    /// the adapter's protected locations, never the target's contents.
    fn check_target(&mut self, target: &Target) -> io::Result<LiveMetadata> {
        self.validate(&self.target(0))?;
        let root = index::identity(&self.explorer.map.nodes[0]);
        let m = self.validate(target)?;
        if m.identity == root || Some(m.identity) == self.filesystem.snapshot_identity() {
            return Err(invalid("scan root and active snapshot are protected"));
        }
        if m.identity.device != root.device || m.mount || m.flags & crate::native::SF_FIRMLINK != 0
        {
            return Err(invalid("operation crosses a mount or firmlink"));
        }
        self.filesystem.refuse_protected_within(target)?;
        Ok(m)
    }
    pub fn prepare(
        &mut self,
        handle: EntryHandle,
        action: Action,
    ) -> io::Result<Confirmation<F::Pin>> {
        let id = self.explorer.resolve(handle)?;
        if id == 0 {
            return Err(invalid("scan root is protected"));
        }
        let target = self.target(id);
        self.check_target(&target)?;
        let pin = self.filesystem.pin(&target)?;
        let metadata = self.validate(&target)?;
        Ok(Confirmation {
            pin,
            metadata,
            handle,
            action,
            target,
        })
    }
    fn begin(&mut self) {
        self.work = UpdateWork::default();
        self.issues.clear();
    }
    fn issue(&mut self, message: impl ToString) {
        self.state.stale = true;
        self.issues.push(message.to_string());
    }
    fn finish(&mut self) -> UpdateReport {
        self.reaccount();
        for id in std::mem::take(&mut self.sort) {
            if self.explorer.is_live(id) {
                self.work.child_ids_sorted += self.explorer.child_ids(id).len();
                self.work.child_ids_copied += self.explorer.child_ids(id).len();
                self.explorer.sort_children(id);
            }
        }
        UpdateReport {
            state: self.state,
            work: self.work,
            issues: std::mem::take(&mut self.issues),
        }
    }
    pub fn execute(&mut self, confirmation: Confirmation<F::Pin>) -> io::Result<OperationReport> {
        self.execute_with(confirmation, None)
    }
    /// `execute` with progress, and Stop for permanent deletion. Deletion checks in
    /// Scanning, unlinks in Removing (`items_examined` counts removed entries) and updates
    /// the inventory in Committed. Stop before the first unlink returns `ScanCancelled`
    /// with nothing changed; a later Stop ends the walk with `Mutation::Partial`. Trash
    /// commits before its checks, so it cannot be stopped.
    pub fn execute_controlled(
        &mut self,
        confirmation: Confirmation<F::Pin>,
        control: &ScanControl,
    ) -> io::Result<OperationReport> {
        control.begin()?;
        let result = self.execute_with(confirmation, Some(control));
        if result.is_ok() {
            control.published();
        }
        control.finish(&result);
        result
    }
    fn execute_with(
        &mut self,
        confirmation: Confirmation<F::Pin>,
        control: Option<&ScanControl>,
    ) -> io::Result<OperationReport> {
        let id = self.explorer.resolve(confirmation.handle)?;
        let current = self.target(id);
        if current.path != confirmation.target.path
            || current.identity != confirmation.target.identity
        {
            return Err(invalid("confirmation target has moved or changed"));
        }
        let deleting = confirmation.action == Action::PermanentlyDelete;
        if let Some(control) = control {
            if deleting {
                control.enter(ScanPhase::Scanning)?;
            } else {
                control.commit_from(ScanPhase::Ready)?;
            }
        }
        let live = self.check_target(&current)?;
        if let Some(control) = control.filter(|_| deleting) {
            control.enter(ScanPhase::Removing)?;
        }
        self.begin();
        let mutation = match confirmation.action {
            Action::Trash => self.filesystem.trash(&current, &confirmation.pin),
            Action::PermanentlyDelete => {
                self.filesystem.remove(&current, &confirmation.pin, control)
            }
        };
        if let Some(control) = control {
            // A failed removal changed nothing, so an accepted Stop is a plain cancellation.
            if matches!(mutation, Mutation::Failed(_))
                && control.progress().phase == ScanPhase::Stopping
            {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    crate::scan_control::ScanCancelled,
                ));
            }
            // The mutation is done; a later Stop changes nothing.
            control.set(ScanPhase::Committed);
        }
        let mut scope = None;
        match &mutation {
            Mutation::Removed => {
                self.state.dirty = true;
                self.set_metadata(id, &ScanMetadata::from(&live));
                let parent = self.explorer.map.nodes[id as usize].parent;
                self.remove_node(id);
                self.refresh_own(parent);
            }
            Mutation::Trashed { destination } => {
                self.state.dirty = true;
                let classified = if self
                    .filesystem
                    .metadata(destination)
                    .is_ok_and(|m| m.identity == current.identity && m.kind == current.kind)
                {
                    self.filesystem.classify_destination(
                        destination,
                        index::identity(&self.explorer.map.nodes[0]),
                    )
                } else {
                    DestinationScope::Unknown
                };
                match &classified {
                    DestinationScope::Outside => {
                        self.set_metadata(id, &ScanMetadata::from(&live));
                        let parent = self.explorer.map.nodes[id as usize].parent;
                        self.remove_node(id);
                        self.refresh_own(parent);
                    }
                    // The saved subtree moves with its saved sizes; nothing below it is read.
                    DestinationScope::Inside(relative) => {
                        if let Err(e) = self.relocate(id, relative, destination) {
                            self.issue(e);
                        }
                    }
                    DestinationScope::Unknown => self
                        .issue("Trash destination scope is unknown; recorded allocation retained"),
                }
                scope = Some(classified);
            }
            Mutation::RemovedWithSkips(_) => {
                self.state.dirty = true;
                let parent = self.explorer.map.nodes[id as usize].parent;
                self.refresh_target(id);
                self.refresh_own(parent);
            }
            Mutation::Partial {
                message, stopped, ..
            } => {
                self.state.dirty = true;
                // The survivors are read again below; only an error leaves them uncertain.
                if !stopped {
                    self.issue(message);
                }
                let parent = self.explorer.map.nodes[id as usize].parent;
                self.refresh_target(id);
                self.refresh_own(parent);
            }
            Mutation::Indeterminate(message) => {
                self.state.dirty = true;
                self.issue(message);
            }
            Mutation::Failed(_) => {}
        }
        Ok(OperationReport {
            mutation,
            scope,
            update: self.finish(),
        })
    }
    /// Recursively refresh only this directory. Failed enumerations retain old children.
    pub fn refresh_directory(&mut self, handle: EntryHandle) -> io::Result<UpdateReport> {
        let id = self.refresh_target_id(handle)?;
        Ok(self.apply_refresh(id))
    }
    /// `refresh_directory` with progress and Stop. It reads the live subtree first and
    /// counts each directory record in `items_examined`. Stop during that read returns
    /// `ScanCancelled` and leaves the inventory unchanged. After the commit point the
    /// in-memory update runs to completion from the read; Stop is then rejected.
    pub fn refresh_directory_controlled(
        &mut self,
        handle: EntryHandle,
        control: &ScanControl,
    ) -> io::Result<UpdateReport> {
        control.begin()?;
        let result = (|| {
            control.enter(ScanPhase::Scanning)?;
            let id = self.refresh_target_id(handle)?;
            let live = self.read_live_subtree(id, control)?;
            control.commit_from(ScanPhase::Scanning)?;
            self.prefetched = Some(live);
            let report = self.apply_refresh(id);
            self.prefetched = None;
            control.published();
            Ok(report)
        })();
        control.finish(&result);
        result
    }
    fn refresh_target_id(&self, handle: EntryHandle) -> io::Result<u32> {
        let id = self.explorer.resolve(handle)?;
        if self.explorer.map.nodes[id as usize].kind != Kind::Dir {
            return Err(invalid("refresh requires a directory"));
        }
        Ok(id)
    }
    fn apply_refresh(&mut self, id: u32) -> UpdateReport {
        self.begin();
        if let Err(e) = self.validate(&self.target(0)) {
            self.issue(e);
        } else {
            self.refresh_target(id);
            if id != 0 {
                let parent = self.explorer.map.nodes[id as usize].parent;
                self.refresh_own(parent);
            }
        }
        self.finish()
    }
}

#[cfg(test)]
mod tests;
