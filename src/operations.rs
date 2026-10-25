//! Explicit live operations over an indexed inventory. Run I/O on a worker thread.
//! Saved reads stay available offline; confirmations are single-use capabilities.
mod index;
pub mod memory;
pub mod native;

use crate::{
    Kind,
    explorer::{EntryHandle, Explorer},
    invalid,
};
use std::{
    collections::{BTreeSet, HashMap, HashSet},
    ffi::OsStr,
    io,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
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
    Trashed {
        destination: PathBuf,
    },
    /// No usable destination, or failure after mutation may have started.
    Indeterminate(String),
    Partial(String),
    /// Adapter guarantees no mutation took place.
    Failed(String),
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
    fn trash(&mut self, target: &Target, pin: &Self::Pin) -> Mutation;
    fn remove(&mut self, target: &Target, pin: &Self::Pin) -> Mutation;
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
/// Clone before moving the session to a worker; poll without locking the session.
#[derive(Clone, Debug, Default)]
pub struct Activity(Arc<AtomicBool>);
impl Activity {
    pub fn is_busy(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
    fn begin(&self) -> BusyGuard {
        self.0.store(true, Ordering::Release);
        BusyGuard(self.clone())
    }
}
struct BusyGuard(Activity);
impl Drop for BusyGuard {
    fn drop(&mut self) {
        self.0.0.store(false, Ordering::Release);
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
    activity: Activity,
    work: UpdateWork,
    groups: BTreeSet<Identity>,
    observations: HashMap<Identity, index::FileObservation>,
    survivor_groups: HashSet<Identity>,
    sort: HashSet<u32>,
    issues: Vec<String>,
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
            activity: Activity::default(),
            state: SessionState {
                dirty: false,
                stale,
            },
            work: UpdateWork::default(),
            groups: BTreeSet::new(),
            observations: HashMap::new(),
            survivor_groups: HashSet::new(),
            sort: HashSet::new(),
            issues: Vec::new(),
        }
    }
    pub fn explorer(&self) -> &Explorer {
        &self.explorer
    }
    pub fn state(&self) -> SessionState {
        self.state
    }
    pub fn activity(&self) -> Activity {
        self.activity.clone()
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
        let _busy = self.activity.begin();
        let id = self.explorer.resolve(handle)?;
        self.validate(&self.target(id))
    }
    fn protect(&mut self, target: &Target) -> io::Result<()> {
        self.validate(&self.target(0))?;
        let root = index::identity(&self.explorer.map.nodes[0]);
        let mut pending = vec![target.clone()];
        let mut seen = HashSet::new();
        while let Some(t) = pending.pop() {
            let m = self.validate(&t)?;
            if m.identity == root || Some(m.identity) == self.filesystem.snapshot_identity() {
                return Err(invalid("scan root and active snapshot are protected"));
            }
            if m.identity.device != root.device
                || m.mount
                || m.flags & crate::native::SF_FIRMLINK != 0
            {
                return Err(invalid("operation crosses a mount or firmlink"));
            }
            if m.kind == Kind::Dir {
                if !seen.insert(m.identity) {
                    return Err(invalid("duplicate directory identity"));
                }
                for e in self.filesystem.read_directory(&t)? {
                    if !crate::valid_basename(&e.name) {
                        return Err(invalid("invalid child name"));
                    }
                    // Descendant symlinks can be unlinked, but are never traversed.
                    if e.metadata.kind != Kind::Symlink {
                        pending.push(Target {
                            path: t.path.join(OsStr::from_bytes(&e.name)),
                            identity: e.metadata.identity,
                            kind: e.metadata.kind,
                        });
                    }
                }
            }
        }
        Ok(())
    }
    pub fn prepare(
        &mut self,
        handle: EntryHandle,
        action: Action,
    ) -> io::Result<Confirmation<F::Pin>> {
        let _busy = self.activity.begin();
        let id = self.explorer.resolve(handle)?;
        if id == 0 {
            return Err(invalid("scan root is protected"));
        }
        let target = self.target(id);
        self.protect(&target)?;
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
        let _busy = self.activity.begin();
        let id = self.explorer.resolve(confirmation.handle)?;
        let current = self.target(id);
        if current.path != confirmation.target.path
            || current.identity != confirmation.target.identity
        {
            return Err(invalid("confirmation target has moved or changed"));
        }
        self.protect(&current)?;
        let live = self.validate(&current)?;
        self.begin();
        let mutation = match confirmation.action {
            Action::Trash => self.filesystem.trash(&current, &confirmation.pin),
            Action::PermanentlyDelete => self.filesystem.remove(&current, &confirmation.pin),
        };
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
                    DestinationScope::Inside(relative) => {
                        if let Err(e) = self.relocate(id, relative, destination) {
                            self.issue(e);
                        } else if current.kind == Kind::Dir {
                            self.refresh_target(id);
                        }
                    }
                    DestinationScope::Unknown => self
                        .issue("Trash destination scope is unknown; recorded allocation retained"),
                }
                scope = Some(classified);
            }
            Mutation::Partial(message) => {
                self.state.dirty = true;
                self.issue(message);
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
        let _busy = self.activity.begin();
        let id = self.explorer.resolve(handle)?;
        if self.explorer.map.nodes[id as usize].kind != Kind::Dir {
            return Err(invalid("refresh requires a directory"));
        }
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
        Ok(self.finish())
    }
}

#[cfg(test)]
mod tests;
