//! Indexed in-memory navigation. Reads never consult the source filesystem.
use crate::{Counters, Kind, Map, invalid};
use std::{
    borrow::Cow,
    collections::{HashMap, HashSet},
    io,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

pub const MAX_PAGE_SIZE: usize = 1024;
static NEXT_SESSION: AtomicU64 = AtomicU64::new(1);

/// Identity within one loaded session, never a lossy name or a persisted snapshot ID.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct EntryHandle {
    session: u64,
    index: u32,
}
impl EntryHandle {
    pub fn session(self) -> u64 {
        self.session
    }
    pub fn index(self) -> u32 {
        self.index
    }
}

/// Immediate saved selection data. Basenames borrow the original name arena.
#[derive(Clone, Debug)]
pub struct EntrySummary<'a> {
    pub handle: EntryHandle,
    pub parent: Option<EntryHandle>,
    pub basename: &'a [u8],
    pub kind: Kind,
    pub allocated_bytes: u64,
    pub accounted_bytes: u64,
    pub subtree_bytes: u64,
    pub child_count: usize,
}
impl EntrySummary<'_> {
    pub fn display_name(&self) -> Cow<'_, str> {
        String::from_utf8_lossy(self.basename)
    }
}
#[derive(Debug)]
pub struct ChildPage<'a> {
    pub entries: Vec<EntrySummary<'a>>,
    pub total: usize,
    pub next_offset: Option<usize>,
    /// Number of child entries read, independent of the directory's total size.
    pub entries_examined: usize,
}
#[derive(Clone, Copy, Debug)]
pub struct StorageStats {
    pub entries: usize,
    pub arena_bytes: usize,
    pub index_bytes: usize,
}

/// Child order: descending subtree allocation, then raw basename, then node ID. Child lists
/// are sorted with it, and `child_rank` binary-searches them with it.
pub(crate) fn child_order(map: &Map, a: u32, b: u32) -> std::cmp::Ordering {
    map.nodes[b as usize]
        .subtree
        .cmp(&map.nodes[a as usize].subtree)
        .then_with(|| map.basename(a as usize).cmp(map.basename(b as usize)))
        .then(a.cmp(&b))
}

/// CSR child lists sorted once in `child_order`.
/// Local mutations replace affected lists without changing navigation/layout.
/// Node slots must not be compacted/reused while session handles remain valid.
#[derive(Debug)]
struct ChildIndex {
    offsets: Vec<u32>,
    ids: Vec<u32>,
    overrides: HashMap<u32, Vec<u32>>,
}
impl ChildIndex {
    fn new(map: &Map) -> Self {
        let mut offsets = vec![0u32; map.nodes.len() + 1];
        for node in map.nodes.iter().skip(1) {
            offsets[node.parent as usize + 1] += 1;
        }
        for i in 1..offsets.len() {
            offsets[i] += offsets[i - 1];
        }
        let mut ids = vec![0; map.nodes.len() - 1];
        // Use the offsets themselves as insertion cursors, then restore starts.
        for (id, node) in map.nodes.iter().enumerate().skip(1) {
            let cursor = &mut offsets[node.parent as usize];
            ids[*cursor as usize] = id as u32;
            *cursor += 1;
        }
        for i in (1..offsets.len()).rev() {
            offsets[i] = offsets[i - 1];
        }
        offsets[0] = 0;
        let mut index = Self {
            offsets,
            ids,
            overrides: HashMap::new(),
        };
        for id in 0..map.nodes.len() {
            let start = index.offsets[id] as usize;
            let end = index.offsets[id + 1] as usize;
            index.ids[start..end].sort_unstable_by(|&a, &b| child_order(map, a, b));
        }
        index
    }
    fn children(&self, id: u32) -> &[u32] {
        if let Some(ids) = self.overrides.get(&id) {
            return ids;
        }
        if id as usize + 1 >= self.offsets.len() {
            return &[];
        }
        &self.ids[self.offsets[id as usize] as usize..self.offsets[id as usize + 1] as usize]
    }
}

#[derive(Debug)]
pub struct Explorer {
    pub(crate) map: Map,
    session: u64,
    children: ChildIndex,
    removed: HashSet<u32>,
}
impl Explorer {
    pub(crate) fn from_map(map: Map) -> io::Result<Self> {
        let session = NEXT_SESSION
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
            .map_err(|_| invalid("explorer session IDs exhausted"))?;
        let children = ChildIndex::new(&map);
        Ok(Self {
            map,
            session,
            children,
            removed: HashSet::new(),
        })
    }
    pub fn root(&self) -> &Path {
        &self.map.root
    }
    pub fn root_handle(&self) -> EntryHandle {
        self.handle(0)
    }
    pub fn counters(&self) -> &Counters {
        &self.map.counters
    }
    pub fn is_partial(&self) -> bool {
        self.map.counters.errors != 0
    }
    pub fn storage_stats(&self) -> StorageStats {
        StorageStats {
            entries: self.map.nodes.len(),
            arena_bytes: self.map.arena_bytes(),
            index_bytes: (self.children.offsets.capacity() + self.children.ids.capacity())
                * size_of::<u32>()
                + self
                    .children
                    .overrides
                    .values()
                    .map(|ids| ids.capacity() * size_of::<u32>())
                    .sum::<usize>()
                + self.removed.capacity() * size_of::<u32>(),
        }
    }
    pub(crate) fn handle(&self, index: u32) -> EntryHandle {
        EntryHandle {
            session: self.session,
            index,
        }
    }
    pub(crate) fn resolve(&self, handle: EntryHandle) -> io::Result<u32> {
        if handle.session != self.session
            || handle.index as usize >= self.map.nodes.len()
            || self.removed.contains(&handle.index)
        {
            return Err(invalid(
                "entry handle does not belong to this explorer session",
            ));
        }
        Ok(handle.index)
    }
    pub(crate) fn child_ids(&self, id: u32) -> &[u32] {
        self.children.children(id)
    }
    pub(crate) fn replace_children(&mut self, id: u32, children: Vec<u32>) {
        self.children.overrides.insert(id, children);
    }
    pub(crate) fn invalidate(&mut self, id: u32) {
        self.removed.insert(id);
        self.children.overrides.remove(&id);
    }
    pub(crate) fn is_live(&self, id: u32) -> bool {
        !self.removed.contains(&id)
    }
    pub(crate) fn sort_children(&mut self, id: u32) {
        let mut children = self.child_ids(id).to_vec();
        children.sort_unstable_by(|&a, &b| child_order(&self.map, a, b));
        self.replace_children(id, children);
    }
    pub fn entry(&self, handle: EntryHandle) -> io::Result<EntrySummary<'_>> {
        let id = self.resolve(handle)?;
        let node = &self.map.nodes[id as usize];
        Ok(EntrySummary {
            handle,
            parent: (id != 0).then(|| self.handle(node.parent)),
            basename: self.map.basename(id as usize),
            kind: node.kind,
            allocated_bytes: node.raw,
            accounted_bytes: node.accounted,
            subtree_bytes: node.subtree,
            child_count: self.child_ids(id).len(),
        })
    }
    /// Raw identity for one selected entry; O(path depth), allocated only on request.
    /// This saved path is not sufficient authorization for a live filesystem action.
    pub fn relative_path(&self, handle: EntryHandle) -> io::Result<Vec<u8>> {
        Ok(self.map.relative_path(self.resolve(handle)? as usize))
    }
    /// Paged direct children, including zero-byte entries. No descendant traversal.
    pub fn children(
        &self,
        parent: EntryHandle,
        offset: usize,
        limit: usize,
    ) -> io::Result<ChildPage<'_>> {
        let id = self.resolve(parent)?;
        if self.map.nodes[id as usize].kind != Kind::Dir {
            return Err(invalid("children require a directory"));
        }
        if !(1..=MAX_PAGE_SIZE).contains(&limit) {
            return Err(invalid("child page limit must be 1..=1024"));
        }
        let children = self.child_ids(id);
        let start = offset.min(children.len());
        let end = start + limit.min(children.len() - start);
        let entries = children[start..end]
            .iter()
            .map(|&id| self.entry(self.handle(id)).unwrap())
            .collect();
        Ok(ChildPage {
            entries,
            total: children.len(),
            next_offset: (end < children.len()).then_some(end),
            entries_examined: end - start,
        })
    }
}

#[cfg(test)]
#[path = "explorer_tests.rs"]
mod tests;
