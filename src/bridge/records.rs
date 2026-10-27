//! Owned, bounded view records. Raw bytes and integer counts remain authoritative.
use super::EntryKey;
use crate::{Kind, explorer, layout, operations};
use std::sync::Arc;

#[derive(Debug, uniffi::Error)]
pub enum BridgeError {
    InvalidInput { message: String },
    InvalidEntry { message: String },
    WrongSession,
    ConsumedAction,
    Cancelled,
    PermissionDenied { message: String },
    NotFound { message: String },
    Io { message: String },
    Internal { message: String },
}
impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for BridgeError {}
impl From<std::io::Error> for BridgeError {
    fn from(e: std::io::Error) -> Self {
        if e.get_ref()
            .is_some_and(|e| e.is::<crate::scan_control::ScanCancelled>())
        {
            return Self::Cancelled;
        }
        let message = e.to_string();
        match e.kind() {
            std::io::ErrorKind::InvalidInput | std::io::ErrorKind::InvalidData => {
                Self::InvalidInput { message }
            }
            std::io::ErrorKind::PermissionDenied => Self::PermissionDenied { message },
            std::io::ErrorKind::NotFound => Self::NotFound { message },
            _ => Self::Io { message },
        }
    }
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
    Other,
}
impl From<Kind> for EntryKind {
    fn from(k: Kind) -> Self {
        match k {
            Kind::File => Self::File,
            Kind::Dir => Self::Directory,
            Kind::Symlink => Self::Symlink,
            Kind::Other => Self::Other,
        }
    }
}
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum ActionKind {
    Trash,
    PermanentlyDelete,
}
impl From<ActionKind> for operations::Action {
    fn from(a: ActionKind) -> Self {
        match a {
            ActionKind::Trash => Self::Trash,
            ActionKind::PermanentlyDelete => Self::PermanentlyDelete,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct EntryRecord {
    pub key: Arc<EntryKey>,
    pub parent: Option<Arc<EntryKey>>,
    pub basename: Vec<u8>,
    pub display_name: String,
    pub kind: EntryKind,
    pub allocated_bytes: u64,
    pub accounted_bytes: u64,
    pub subtree_bytes: u64,
    pub child_count: u64,
}
impl From<explorer::EntrySummary<'_>> for EntryRecord {
    fn from(e: explorer::EntrySummary<'_>) -> Self {
        Self {
            key: EntryKey::new(e.handle),
            parent: e.parent.map(EntryKey::new),
            basename: e.basename.to_vec(),
            display_name: e.display_name().into_owned(),
            kind: e.kind.into(),
            allocated_bytes: e.allocated_bytes,
            accounted_bytes: e.accounted_bytes,
            subtree_bytes: e.subtree_bytes,
            child_count: e.child_count as u64,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct SelectionRecord {
    pub entry: EntryRecord,
    pub relative_path: Vec<u8>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ChildrenRecord {
    pub entries: Vec<EntryRecord>,
    pub total: u64,
    pub next_offset: Option<u64>,
    pub entries_examined: u64,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ScanCounters {
    pub symlinks: u64,
    pub mounts: u64,
    pub firmlinks: u64,
    pub errors: u64,
    pub metadata_fallbacks: u64,
    pub root_fstats: u64,
    pub directory_fstats: u64,
    pub duplicate_dirs: u64,
}
impl From<&crate::Counters> for ScanCounters {
    fn from(c: &crate::Counters) -> Self {
        Self {
            symlinks: c.symlinks,
            mounts: c.mounts,
            firmlinks: c.firmlinks,
            errors: c.errors,
            metadata_fallbacks: c.metadata_fallbacks,
            root_fstats: c.root_fstats,
            directory_fstats: c.directory_fstats,
            duplicate_dirs: c.duplicate_dirs,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct SessionStatus {
    pub simulated: bool,
    pub root: EntryRecord,
    pub root_path: Vec<u8>,
    pub scan_partial: bool,
    pub dirty: bool,
    pub stale: bool,
    pub counters: ScanCounters,
    /// Arena slots include tombstones; not a live-entry count.
    pub arena_slots: u64,
    pub arena_bytes: u64,
    pub navigation_index_bytes: u64,
    pub identity_index_bytes: u64,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataRecord {
    pub device: u64,
    pub inode: u64,
    pub kind: EntryKind,
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
impl From<&operations::LiveMetadata> for MetadataRecord {
    fn from(m: &operations::LiveMetadata) -> Self {
        Self {
            device: m.identity.device,
            inode: m.identity.inode,
            kind: m.kind.into(),
            allocated_bytes: m.allocated_bytes,
            logical_bytes: m.logical_bytes,
            links: m.links,
            mode: m.mode,
            modified_seconds: m.modified_seconds,
            modified_nanoseconds: m.modified_nanoseconds,
            created_seconds: m.created_seconds,
            flags: m.flags,
            mount: m.mount,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ConfirmationDetails {
    pub key: Arc<EntryKey>,
    pub action: ActionKind,
    pub raw_path: Vec<u8>,
    pub metadata: MetadataRecord,
}
#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct Rectangle {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl From<layout::Rect> for Rectangle {
    fn from(r: layout::Rect) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}
impl From<Rectangle> for layout::Rect {
    fn from(r: Rectangle) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct LayoutRequest {
    pub viewport: Rectangle,
    pub max_rectangles: u32,
    pub min_area: f64,
    pub max_depth: u32,
}
#[derive(Clone, Debug, uniffi::Enum)]
pub enum RegionKind {
    Entry {
        key: Arc<EntryKey>,
    },
    Rollup {
        directory: Arc<EntryKey>,
        omitted_children: u64,
    },
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct TileRecord {
    pub kind: RegionKind,
    pub rect: Rectangle,
    pub bytes: u64,
    pub depth: u32,
    pub parent: Option<Arc<EntryKey>>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct GroupRecord {
    pub directory: Arc<EntryKey>,
    pub rect: Rectangle,
    pub depth: u32,
    pub parent: Option<Arc<EntryKey>>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct LayoutRecord {
    pub focus: Arc<EntryKey>,
    pub total_bytes: u64,
    pub tiles: Vec<TileRecord>,
    pub groups: Vec<GroupRecord>,
    pub entries_examined: u64,
    pub child_ids_examined: u64,
    pub directories_expanded: u64,
}
impl From<layout::Layout> for LayoutRecord {
    fn from(l: layout::Layout) -> Self {
        Self {
            focus: EntryKey::new(l.focus),
            total_bytes: l.total_bytes,
            tiles: l
                .tiles
                .into_iter()
                .map(|t| TileRecord {
                    kind: match t.kind {
                        layout::TileKind::Entry(h) => RegionKind::Entry {
                            key: EntryKey::new(h),
                        },
                        layout::TileKind::Rollup {
                            directory,
                            omitted_children,
                        } => RegionKind::Rollup {
                            directory: EntryKey::new(directory),
                            omitted_children: omitted_children as u64,
                        },
                    },
                    rect: t.rect.into(),
                    bytes: t.bytes,
                    depth: t.depth,
                    parent: t.parent.map(EntryKey::new),
                })
                .collect(),
            groups: l
                .groups
                .into_iter()
                .map(|g| GroupRecord {
                    directory: EntryKey::new(g.directory),
                    rect: g.rect.into(),
                    depth: g.depth,
                    parent: g.parent.map(EntryKey::new),
                })
                .collect(),
            entries_examined: l.work.entries_examined as u64,
            child_ids_examined: l.work.child_ids_examined as u64,
            directories_expanded: l.work.directories_expanded as u64,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct UpdateRecord {
    pub dirty: bool,
    pub stale: bool,
    pub issues: Vec<String>,
    pub issues_omitted: u64,
    pub nodes_examined: u64,
    pub identity_comparisons: u64,
    pub identity_members: u64,
    pub ancestor_updates: u64,
    pub child_ids_copied: u64,
    pub child_ids_sorted: u64,
    pub directories_read: u64,
}
impl From<operations::UpdateReport> for UpdateRecord {
    fn from(mut r: operations::UpdateReport) -> Self {
        let issues_omitted = r.issues.len().saturating_sub(64) as u64;
        r.issues.truncate(64);
        Self {
            dirty: r.state.dirty,
            stale: r.state.stale,
            issues: r.issues,
            issues_omitted,
            nodes_examined: r.work.nodes_examined as u64,
            identity_comparisons: r.work.identity_comparisons as u64,
            identity_members: r.work.identity_members as u64,
            ancestor_updates: r.work.ancestor_updates as u64,
            child_ids_copied: r.work.child_ids_copied as u64,
            child_ids_sorted: r.work.child_ids_sorted as u64,
            directories_read: r.work.directories_read as u64,
        }
    }
}
#[derive(Clone, Debug, uniffi::Enum)]
pub enum MutationOutcome {
    Removed,
    Trashed { destination: Vec<u8> },
    Indeterminate { message: String },
    Partial { message: String },
    Failed { message: String },
}
#[derive(Clone, Debug, uniffi::Enum)]
pub enum TrashScope {
    Inside { relative_path: Vec<u8> },
    Outside,
    Unknown,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct OperationRecord {
    pub mutation: MutationOutcome,
    pub scope: Option<TrashScope>,
    pub update: UpdateRecord,
}
impl From<operations::OperationReport> for OperationRecord {
    fn from(r: operations::OperationReport) -> Self {
        use std::os::unix::ffi::OsStrExt;
        Self {
            mutation: match r.mutation {
                operations::Mutation::Removed => MutationOutcome::Removed,
                operations::Mutation::Trashed { destination } => MutationOutcome::Trashed {
                    destination: destination.as_os_str().as_bytes().to_vec(),
                },
                operations::Mutation::Indeterminate(message) => {
                    MutationOutcome::Indeterminate { message }
                }
                operations::Mutation::Partial(message) => MutationOutcome::Partial { message },
                operations::Mutation::Failed(message) => MutationOutcome::Failed { message },
            },
            scope: r.scope.map(|s| match s {
                operations::DestinationScope::Inside(relative_path) => {
                    TrashScope::Inside { relative_path }
                }
                operations::DestinationScope::Outside => TrashScope::Outside,
                operations::DestinationScope::Unknown => TrashScope::Unknown,
            }),
            update: r.update.into(),
        }
    }
}
