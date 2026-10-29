//! Generated native-client facade. All methods are synchronous; dispatch off the UI thread.
mod fixture;
mod records;
mod views;
pub use crate::scan_control::{ScanControl, ScanPhase, ScanProgress};
use crate::{
    explorer::{EntryHandle, Explorer},
    inventory::{Inventory, ScanOptions},
    layout::LayoutOptions,
    operations::{
        Confirmation, OperationSession,
        memory::{MemoryFileSystem, MemoryPin, StageGate},
        native::{NativeFileSystem, NativePin},
    },
};
pub use records::*;
use std::{
    ffi::OsString,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::PathBuf,
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
};
pub use views::*;

/// Opaque saved identity, not an operation capability. Swift cannot manufacture keys.
#[derive(Debug, uniffi::Object)]
pub struct EntryKey {
    handle: EntryHandle,
}
impl EntryKey {
    fn new(handle: EntryHandle) -> Arc<Self> {
        Arc::new(Self { handle })
    }
}
#[uniffi::export]
impl EntryKey {
    pub fn same_entry(&self, other: Arc<EntryKey>) -> bool {
        self.handle == other.handle
    }
}

// Both sessions are large and differ in size; the session lives behind one mutex.
enum Backend {
    Native(Box<OperationSession<NativeFileSystem>>),
    Memory(Box<OperationSession<MemoryFileSystem>>),
}
// Dispatch only: every computation and operation stays in the existing core.
macro_rules! dispatch {
    ($backend:expr, $s:ident => $body:expr) => {
        match $backend {
            Backend::Native($s) => $body,
            Backend::Memory($s) => $body,
        }
    };
}
impl Backend {
    fn explorer(&self) -> &Explorer {
        dispatch!(self, s => s.explorer())
    }
    fn validate(&self, key: &EntryKey) -> Result<EntryHandle, BridgeError> {
        self.explorer()
            .entry(key.handle)
            .map_err(|e| BridgeError::InvalidEntry {
                message: e.to_string(),
            })?;
        Ok(key.handle)
    }
}
enum PinnedAction {
    Native(Confirmation<NativePin>),
    Memory(Confirmation<MemoryPin>),
}

/// Owns the actual core confirmation. Cancel/drop releases its pin without session locking.
#[derive(uniffi::Object)]
pub struct PreparedAction {
    session: u64,
    details: ConfirmationDetails,
    pin: Mutex<Option<PinnedAction>>,
}
#[uniffi::export]
impl PreparedAction {
    pub fn details(&self) -> ConfirmationDetails {
        self.details.clone()
    }
    pub fn cancel(&self) -> Result<(), BridgeError> {
        lock(&self.pin)?.take().ok_or(BridgeError::ConsumedAction)?;
        Ok(())
    }
}

#[derive(uniffi::Object)]
pub struct ExplorerSession {
    backend: Mutex<Backend>,
    // Counts both queued and running calls, independent of the backend lock.
    active: AtomicUsize,
    revision: AtomicU64,
    selection_queries: AtomicU64,
    /// The stage gate of a paused fixture scenario, outside the backend lock.
    gate: Option<Arc<StageGate>>,
}
struct ActiveCall<'a>(&'a AtomicUsize);
impl Drop for ActiveCall<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Release);
    }
}
fn lock<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>, BridgeError> {
    mutex.lock().map_err(|_| BridgeError::Internal {
        message: "session/action lock poisoned; discard the session".into(),
    })
}
fn path(bytes: Vec<u8>) -> Result<PathBuf, BridgeError> {
    if bytes.is_empty() || bytes.contains(&0) {
        return Err(BridgeError::InvalidInput {
            message: "path must be nonempty and contain no NUL".into(),
        });
    }
    Ok(PathBuf::from(OsString::from_vec(bytes)))
}
impl ExplorerSession {
    fn new(mut backend: Backend) -> Arc<Self> {
        let gate = match &mut backend {
            Backend::Memory(s) => s.filesystem_mut().stages.gate.clone(),
            Backend::Native(_) => None,
        };
        Arc::new(Self {
            backend: Mutex::new(backend),
            active: AtomicUsize::new(0),
            revision: AtomicU64::new(0),
            selection_queries: AtomicU64::new(0),
            gate,
        })
    }
    fn gate(&self) -> Result<&StageGate, BridgeError> {
        self.gate
            .as_deref()
            .ok_or_else(|| BridgeError::InvalidInput {
                message: "only a paused fixture scenario has a stage gate".into(),
            })
    }
    fn with<T>(
        &self,
        f: impl FnOnce(&mut Backend) -> Result<T, BridgeError>,
    ) -> Result<T, BridgeError> {
        self.active.fetch_add(1, Ordering::AcqRel);
        let _active = ActiveCall(&self.active);
        f(&mut *lock(&self.backend)?)
    }
}
#[uniffi::export]
impl ExplorerSession {
    #[uniffi::constructor]
    pub fn open_snapshot(snapshot_path: Vec<u8>) -> Result<Arc<Self>, BridgeError> {
        Ok(Self::new(Backend::Native(Box::new(
            NativeFileSystem::open_snapshot(&path(snapshot_path)?)?,
        ))))
    }
    /// Create once, release the returned inventory, then reopen/pin the saved inode.
    #[uniffi::constructor]
    pub fn create(
        source_root: Vec<u8>,
        snapshot_path: Vec<u8>,
        workers: u32,
    ) -> Result<Arc<Self>, BridgeError> {
        let root = path(source_root)?;
        let snapshot = path(snapshot_path)?;
        drop(Inventory::create(
            &root,
            &snapshot,
            ScanOptions {
                workers: workers as usize,
            },
        )?);
        Ok(Self::new(Backend::Native(Box::new(
            NativeFileSystem::open_snapshot(&snapshot)?,
        ))))
    }
    /// The independently owned control remains pollable while this constructor runs.
    #[uniffi::constructor]
    pub fn create_controlled(
        source_root: Vec<u8>,
        snapshot_path: Vec<u8>,
        workers: u32,
        control: Arc<ScanControl>,
    ) -> Result<Arc<Self>, BridgeError> {
        // Path validation belongs to the controlled operation so errors terminate progress.
        let paths = path(source_root).and_then(|root| Ok((root, path(snapshot_path)?)));
        let (root, snapshot) = match paths {
            Ok(paths) => paths,
            Err(error) => {
                control.begin()?;
                control.set(ScanPhase::Failed);
                return Err(error);
            }
        };
        drop(Inventory::create_controlled(
            &root,
            &snapshot,
            ScanOptions {
                workers: workers as usize,
            },
            &control,
        )?);
        control.set(ScanPhase::PreparingView);
        let result = NativeFileSystem::open_snapshot(&snapshot);
        control.finish(&result);
        let session = Self::new(Backend::Native(Box::new(result?)));
        control.set(ScanPhase::Complete);
        Ok(session)
    }
    /// Explicit simulated constructor. Unknown scenarios fail closed; never opens native paths.
    #[uniffi::constructor]
    pub fn fixture(scenario: String) -> Result<Arc<Self>, BridgeError> {
        Ok(Self::new(Backend::Memory(Box::new(fixture::session(
            &scenario,
        )?))))
    }
    pub fn is_busy(&self) -> bool {
        self.active.load(Ordering::Acquire) != 0
    }
    /// Calls queued on or currently holding the backend lock; diagnostic, not a lock barrier.
    pub fn active_call_count(&self) -> u64 {
        self.active.load(Ordering::Acquire) as u64
    }
    pub fn status(&self) -> Result<SessionStatus, BridgeError> {
        self.with(|b| {
            let e = b.explorer();
            let state = dispatch!(&*b, s => s.state());
            let storage = e.storage_stats();
            Ok(SessionStatus {
                simulated: matches!(b, Backend::Memory(_)),
                root: e.entry(e.root_handle())?.into(),
                root_path: e.root().as_os_str().as_bytes().to_vec(),
                scan_partial: e.is_partial(),
                dirty: state.dirty,
                stale: state.stale,
                counters: e.counters().into(),
                arena_slots: storage.entries as u64,
                arena_bytes: storage.arena_bytes as u64,
                navigation_index_bytes: storage.index_bytes as u64,
                identity_index_bytes: dispatch!(&*b, s => s.identity_index_bytes()) as u64,
            })
        })
    }
    pub fn children(
        &self,
        parent: Arc<EntryKey>,
        offset: u64,
        limit: u32,
    ) -> Result<ChildrenRecord, BridgeError> {
        self.with(|b| {
            let h = b.validate(&parent)?;
            let offset = usize::try_from(offset).map_err(|_| BridgeError::InvalidInput {
                message: "offset exceeds platform range".into(),
            })?;
            let p = b.explorer().children(h, offset, limit as usize)?;
            Ok(ChildrenRecord {
                entries: p.entries.into_iter().map(Into::into).collect(),
                total: p.total as u64,
                next_offset: p.next_offset.map(|n| n as u64),
                entries_examined: p.entries_examined as u64,
            })
        })
    }
    /// Saved selection queries actually entered under the backend lock, including invalid keys.
    pub fn selection_query_count(&self) -> u64 {
        self.selection_queries.load(Ordering::Relaxed)
    }
    pub fn selection(&self, key: Arc<EntryKey>) -> Result<SelectionRecord, BridgeError> {
        self.with(|b| {
            self.selection_queries.fetch_add(1, Ordering::Relaxed);
            let h = b.validate(&key)?;
            Ok(SelectionRecord {
                entry: b.explorer().entry(h)?.into(),
                relative_path: b.explorer().relative_path(h)?,
            })
        })
    }
    pub fn layout(
        &self,
        focus: Arc<EntryKey>,
        request: LayoutRequest,
    ) -> Result<LayoutRecord, BridgeError> {
        self.with(|b| {
            let h = b.validate(&focus)?;
            Ok(b.explorer()
                .layout(
                    h,
                    LayoutOptions {
                        viewport: request.viewport.into(),
                        max_rectangles: request.max_rectangles as usize,
                        min_area: request.min_area,
                        max_depth: request.max_depth,
                    },
                )?
                .into())
        })
    }
    pub fn live_metadata(&self, key: Arc<EntryKey>) -> Result<MetadataRecord, BridgeError> {
        self.with(|b| {
            let h = b.validate(&key)?;
            Ok((&dispatch!(b, s => s.live_metadata(h))?).into())
        })
    }
    pub fn prepare(
        &self,
        key: Arc<EntryKey>,
        action: ActionKind,
    ) -> Result<Arc<PreparedAction>, BridgeError> {
        self.with(|b| {
            let h = b.validate(&key)?;
            let (details, pin) = match b {
                Backend::Native(s) => {
                    let c = s.prepare(h, action.into())?;
                    (confirmation_details(&c, action), PinnedAction::Native(c))
                }
                Backend::Memory(s) => {
                    let c = s.prepare(h, action.into())?;
                    (confirmation_details(&c, action), PinnedAction::Memory(c))
                }
            };
            Ok(Arc::new(PreparedAction {
                session: h.session(),
                details,
                pin: Mutex::new(Some(pin)),
            }))
        })
    }
    /// A cross-session attempt does not consume the action. Any same-session attempt does.
    pub fn execute(&self, action: Arc<PreparedAction>) -> Result<OperationRecord, BridgeError> {
        self.with(|b| {
            if action.session != b.explorer().root_handle().session() {
                return Err(BridgeError::WrongSession);
            }
            let pin = lock(&action.pin)?
                .take()
                .ok_or(BridgeError::ConsumedAction)?;
            self.revision.fetch_add(1, Ordering::AcqRel);
            let report = match (b, pin) {
                (Backend::Native(s), PinnedAction::Native(c)) => s.execute(c)?,
                (Backend::Memory(s), PinnedAction::Memory(c)) => s.execute(c)?,
                _ => return Err(BridgeError::WrongSession),
            };
            Ok(report.into())
        })
    }
    /// `execute` with the scan's progress. Deletion: Stop before the first unlink returns
    /// `BridgeError.Cancelled` with nothing changed and every view still valid; a later Stop
    /// ends with `MutationOutcome.Partial` (`stopped`). Trash cannot be stopped.
    pub fn execute_controlled(
        &self,
        action: Arc<PreparedAction>,
        control: Arc<ScanControl>,
    ) -> Result<OperationRecord, BridgeError> {
        self.with(|b| {
            let pin = if action.session != b.explorer().root_handle().session() {
                Err(BridgeError::WrongSession)
            } else {
                lock(&action.pin)?.take().ok_or(BridgeError::ConsumedAction)
            };
            let report = match (b, pin) {
                (Backend::Native(s), Ok(PinnedAction::Native(c))) => {
                    s.execute_controlled(c, &control)
                }
                (Backend::Memory(s), Ok(PinnedAction::Memory(c))) => {
                    s.execute_controlled(c, &control)
                }
                (_, pin) => {
                    control.begin()?;
                    control.set(ScanPhase::Failed);
                    return Err(pin.err().unwrap_or(BridgeError::WrongSession));
                }
            }
            .map_err(BridgeError::from);
            // Like `execute`, any claimed attempt makes old views stale, except a Stop that
            // won before the first removal: nothing changed, so frames, trees and hits stay valid.
            if !matches!(report, Err(BridgeError::Cancelled)) {
                self.revision.fetch_add(1, Ordering::AcqRel);
            }
            let report = report?;
            control.set(ScanPhase::Complete);
            Ok(report.into())
        })
    }
    /// Fixture only: waits up to 10 s until a paused scenario holds an operation, and
    /// returns the stage ("check", "trash", "remove" or "update").
    pub fn wait_for_held_fixture_stage(&self) -> Result<String, BridgeError> {
        self.gate()?
            .wait_for_held(std::time::Duration::from_secs(10))
            .map(|stage| stage.name().to_string())
            .ok_or_else(|| BridgeError::Internal {
                message: "no fixture stage was held within 10 s".into(),
            })
    }
    /// Fixture only: lets the held operation continue to its next stage.
    pub fn release_fixture_stage(&self) -> Result<(), BridgeError> {
        self.gate()?.release();
        Ok(())
    }
    pub fn refresh_directory(&self, key: Arc<EntryKey>) -> Result<UpdateRecord, BridgeError> {
        self.with(|b| {
            let h = b.validate(&key)?;
            self.revision.fetch_add(1, Ordering::AcqRel);
            Ok(dispatch!(b, s => s.refresh_directory(h))?.into())
        })
    }
    /// Refresh with the scan's progress and Stop. `BridgeError.Cancelled` means Stop won
    /// before the update: the inventory and every view query stay valid and unchanged.
    pub fn refresh_directory_controlled(
        &self,
        key: Arc<EntryKey>,
        control: Arc<ScanControl>,
    ) -> Result<UpdateRecord, BridgeError> {
        self.with(|b| {
            let h = match b.validate(&key) {
                Ok(h) => h,
                Err(error) => {
                    control.begin()?;
                    control.set(ScanPhase::Failed);
                    return Err(error);
                }
            };
            // The session lock is held for the whole call, so no query can observe the
            // update before this revision change. A stopped or failed refresh changes no
            // data, so the old frames, trees and hits stay valid.
            let report = dispatch!(b, s => s.refresh_directory_controlled(h, &control))?;
            self.revision.fetch_add(1, Ordering::AcqRel);
            control.set(ScanPhase::Complete);
            Ok(report.into())
        })
    }
}
fn confirmation_details<P>(c: &Confirmation<P>, action: ActionKind) -> ConfirmationDetails {
    ConfirmationDetails {
        key: EntryKey::new(c.handle()),
        action,
        raw_path: c.path().as_os_str().as_bytes().to_vec(),
        metadata: c.metadata().into(),
    }
}

#[cfg(test)]
mod tests;
