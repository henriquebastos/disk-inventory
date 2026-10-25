use super::*;
use crate::{Entry, Node};
use std::collections::BTreeMap;

pub(super) fn identity(n: &Node) -> Identity {
    Identity {
        device: n.dev,
        inode: n.ino,
    }
}
/// Every original identity is indexed, including files originally reporting links=1.
/// Baseline keys never change; tombstones are filtered after binary search. New slots
/// use a small overlay rather than inserting into a multi-million-entry sorted array.
pub(super) struct IdentityIndex {
    base: Vec<u32>,
    added: BTreeMap<Identity, Vec<u32>>,
}
impl IdentityIndex {
    pub fn new(e: &Explorer) -> Self {
        let mut base: Vec<_> = (0..e.map.nodes.len() as u32).collect();
        base.sort_unstable_by_key(|&id| identity(&e.map.nodes[id as usize]));
        Self {
            base,
            added: BTreeMap::new(),
        }
    }
    pub fn base_bytes(&self) -> usize {
        self.base.capacity() * size_of::<u32>()
    }
    fn members(&self, key: Identity, e: &Explorer, work: &mut UpdateWork) -> Vec<u32> {
        let start = self.base.partition_point(|&id| {
            work.identity_comparisons += 1;
            identity(&e.map.nodes[id as usize]) < key
        });
        let mut ids = Vec::new();
        for &id in &self.base[start..] {
            work.identity_comparisons += 1;
            if identity(&e.map.nodes[id as usize]) != key {
                break;
            }
            work.identity_members += 1;
            if e.is_live(id) {
                ids.push(id);
            }
        }
        if let Some(added) = self.added.get(&key) {
            work.identity_members += added.len();
            ids.extend(added.iter().copied().filter(|&id| e.is_live(id)));
        }
        ids
    }
}
impl<F: FileSystem> OperationSession<F> {
    fn members(&mut self, key: Identity) -> Vec<u32> {
        self.identities.members(key, &self.explorer, &mut self.work)
    }
    fn delta(&mut self, id: u32, delta: i128) -> bool {
        if delta == 0 {
            return true;
        }
        // Validate the entire ancestor chain before changing any total.
        let mut current = id;
        loop {
            self.work.ancestor_updates += 1;
            let n = &self.explorer.map.nodes[current as usize];
            if u64::try_from(i128::from(n.subtree) + delta).is_err() {
                self.issue("incremental accounting overflow; previous attributed totals retained");
                return false;
            }
            if current == 0 {
                break;
            }
            current = n.parent;
        }
        let mut current = id;
        loop {
            self.work.ancestor_updates += 1;
            let n = &mut self.explorer.map.nodes[current as usize];
            n.subtree = (i128::from(n.subtree) + delta) as u64;
            if current == 0 {
                break;
            }
            let parent = n.parent;
            self.sort.insert(parent);
            current = parent;
        }
        true
    }
    fn accounted(&mut self, id: u32, bytes: u64) {
        let old = self.explorer.map.nodes[id as usize].accounted;
        if self.delta(id, i128::from(bytes) - i128::from(old)) {
            self.explorer.map.nodes[id as usize].accounted = bytes;
        }
    }
    pub(super) fn reaccount(&mut self) {
        for key in std::mem::take(&mut self.groups) {
            let members = self.members(key);
            let owner = members
                .iter()
                .filter(|&&id| self.explorer.map.nodes[id as usize].kind == Kind::File)
                .min_by_key(|&&id| self.explorer.map.relative_path(id as usize))
                .copied();
            // Subtract old ownership before adding a new owner, avoiding transient overflow.
            for &id in &members {
                if self.explorer.map.nodes[id as usize].kind == Kind::File && Some(id) != owner {
                    self.accounted(id, 0);
                }
            }
            if let Some(id) = owner {
                self.accounted(id, self.explorer.map.nodes[id as usize].raw);
            }
        }
    }
    pub(super) fn set_metadata(&mut self, id: u32, m: &LiveMetadata) {
        self.work.nodes_examined += 1;
        let changed = {
            let n = &self.explorer.map.nodes[id as usize];
            n.raw != m.allocated_bytes || n.links != m.links
        };
        if !changed {
            return;
        }
        self.state.dirty = true;
        if m.kind == Kind::File {
            for alias in self.members(m.identity) {
                let n = &mut self.explorer.map.nodes[alias as usize];
                if n.kind == Kind::File {
                    n.raw = m.allocated_bytes;
                    n.links = m.links;
                }
            }
            self.groups.insert(m.identity);
        } else {
            self.explorer.map.nodes[id as usize].raw = m.allocated_bytes;
            self.accounted(id, m.allocated_bytes);
        }
    }
    fn append(&mut self, parent: u32, name: &[u8], m: &LiveMetadata) -> io::Result<u32> {
        self.append_entry(parent, name, m, true)
    }
    fn append_entry(
        &mut self,
        parent: u32,
        name: &[u8],
        m: &LiveMetadata,
        attach: bool,
    ) -> io::Result<u32> {
        if m.kind == Kind::Dir
            && self
                .members(m.identity)
                .iter()
                .any(|&id| self.explorer.map.nodes[id as usize].kind == Kind::Dir)
        {
            return Err(invalid(
                "duplicate directory identity; new alias not traversed",
            ));
        }
        let id = self.explorer.map.add(
            parent,
            name,
            Entry {
                kind: m.kind,
                dev: m.identity.device,
                ino: m.identity.inode,
                flags: m.flags,
                links: m.links,
                allocation: Some(m.allocated_bytes),
                mount: u32::from(m.mount),
            },
        )?;
        self.explorer.map.nodes[id as usize].accounted = 0;
        self.explorer.map.nodes[id as usize].subtree = 0;
        self.identities
            .added
            .entry(m.identity)
            .or_default()
            .push(id);
        if attach {
            let mut children = self.explorer.child_ids(parent).to_vec();
            self.work.child_ids_copied += children.len();
            children.push(id);
            self.explorer.replace_children(parent, children);
        }
        self.sort.insert(parent);
        self.state.dirty = true;
        if m.kind == Kind::File {
            // A new alias can update an original links=1 alias outside this subtree.
            for alias in self.members(m.identity) {
                self.explorer.map.nodes[alias as usize].raw = m.allocated_bytes;
            }
            self.groups.insert(m.identity);
        } else {
            self.accounted(id, m.allocated_bytes);
        }
        Ok(id)
    }
    pub(super) fn remove_node(&mut self, id: u32) {
        self.remove_entry(id, true);
    }
    fn remove_entry(&mut self, id: u32, detach: bool) {
        let parent = self.explorer.map.nodes[id as usize].parent;
        let bytes = self.explorer.map.nodes[id as usize].subtree;
        self.delta(parent, -i128::from(bytes));
        if detach {
            let mut children = self.explorer.child_ids(parent).to_vec();
            self.work.child_ids_copied += children.len();
            children.retain(|&child| child != id); // Removing children preserves their ordering.
            self.explorer.replace_children(parent, children);
        }
        let mut pending = vec![id];
        while let Some(id) = pending.pop() {
            self.work.nodes_examined += 1;
            self.work.child_ids_copied += self.explorer.child_ids(id).len();
            pending.extend_from_slice(self.explorer.child_ids(id));
            let n = &mut self.explorer.map.nodes[id as usize];
            if n.kind == Kind::File {
                self.groups.insert(identity(n));
            }
            n.accounted = 0;
            n.subtree = 0;
            self.explorer.invalidate(id);
        }
        self.state.dirty = true;
    }
    fn eligible(&self, m: &LiveMetadata) -> bool {
        m.kind != Kind::Symlink
            && m.identity.device == self.explorer.map.nodes[0].dev
            && !m.mount
            && m.flags & crate::native::SF_FIRMLINK == 0
            && Some(m.identity) != self.filesystem.snapshot_identity()
    }
    pub(super) fn refresh_own(&mut self, id: u32) {
        match self.validate(&self.target(id)) {
            Ok(m) => self.set_metadata(id, &m),
            Err(e) => self.issue(e),
        }
    }
    pub(super) fn refresh_target(&mut self, id: u32) {
        let mut pending = vec![id];
        let mut seen = HashSet::new();
        let mut observed = HashMap::new();
        while let Some(id) = pending.pop() {
            let target = self.target(id);
            let m = match self.filesystem.metadata(&target.path) {
                Ok(m) => m,
                Err(e) if e.kind() == io::ErrorKind::NotFound && id != 0 => {
                    self.remove_node(id);
                    continue;
                }
                Err(e) => {
                    self.issue(e);
                    continue;
                }
            };
            if m.identity != target.identity || m.kind != target.kind {
                // The old handle must never authorize its replacement.
                if id == 0 {
                    self.issue("scan root identity changed");
                    continue;
                }
                let parent = self.explorer.map.nodes[id as usize].parent;
                let name = self.explorer.map.basename(id as usize).to_vec();
                self.remove_node(id);
                if self.eligible(&m) {
                    match self.append(parent, &name, &m) {
                        Ok(new) => pending.push(new),
                        Err(e) => self.issue(e),
                    }
                }
                continue;
            }
            if !self.eligible(&m) {
                if id != 0 {
                    self.remove_node(id);
                } else {
                    self.issue("scan root is no longer eligible");
                }
                continue;
            }
            self.set_metadata(id, &m);
            if m.kind != Kind::Dir {
                continue;
            }
            if !seen.insert(m.identity) {
                self.issue("duplicate directory identity during refresh");
                continue;
            }
            self.work.directories_read += 1;
            let entries = match self.filesystem.read_directory(&target) {
                Ok(entries) => entries,
                Err(e) => {
                    self.issue(e);
                    continue;
                }
            };
            let mut names = HashSet::new();
            if entries.iter().any(|e| {
                !crate::valid_basename(&e.name)
                    || !names.insert(e.name.clone())
                    || e.metadata.allocated_bytes > i64::MAX as u64
            }) {
                self.issue("invalid or duplicate directory record");
                continue;
            }
            let old: HashMap<Vec<u8>, u32> = self
                .explorer
                .child_ids(id)
                .iter()
                .map(|&child| (self.explorer.map.basename(child as usize).to_vec(), child))
                .collect();
            self.work.nodes_examined += old.len() + entries.len();
            // Remove missing/ineligible/replaced entries before insertions and accounting.
            let current: HashMap<_, _> = entries
                .iter()
                .map(|e| (e.name.as_slice(), &e.metadata))
                .collect();
            for (name, &child) in &old {
                let n = &self.explorer.map.nodes[child as usize];
                if !current.get(name.as_slice()).is_some_and(|m| {
                    self.eligible(m) && m.identity == identity(n) && m.kind == n.kind
                }) {
                    self.remove_entry(child, false);
                }
            }
            self.work.child_ids_copied += self.explorer.child_ids(id).len();
            let mut children: Vec<_> = self
                .explorer
                .child_ids(id)
                .iter()
                .copied()
                .filter(|&child| self.explorer.is_live(child))
                .collect();
            for entry in entries {
                let m = &entry.metadata;
                if !self.eligible(m) {
                    continue;
                }
                if m.kind == Kind::File
                    && observed
                        .insert(m.identity, m.allocated_bytes)
                        .is_some_and(|raw| raw != m.allocated_bytes)
                {
                    self.issue("conflicting allocation observations for one inode");
                    continue;
                }
                let child = if let Some(&child) = old
                    .get(&entry.name)
                    .filter(|&&child| self.explorer.is_live(child))
                {
                    self.set_metadata(child, m);
                    child
                } else {
                    match self.append_entry(id, &entry.name, m, false) {
                        Ok(child) => {
                            children.push(child);
                            child
                        }
                        Err(e) => {
                            self.issue(e);
                            continue;
                        }
                    }
                };
                if m.kind == Kind::Dir {
                    pending.push(child);
                }
            }
            self.explorer.replace_children(id, children);
        }
    }
    pub(super) fn relocate(
        &mut self,
        id: u32,
        relative: &[u8],
        destination: &Path,
    ) -> io::Result<()> {
        let parts: Vec<_> = relative.split(|&b| b == b'/').collect();
        if parts.is_empty() || parts.iter().any(|p| !crate::valid_basename(p)) {
            return Err(invalid("invalid in-scope destination"));
        }
        let target = self.target(id);
        let moved = self.filesystem.metadata(destination)?;
        if moved.identity != target.identity || moved.kind != target.kind {
            return Err(invalid("Trash destination identity changed"));
        }
        let mut parent = 0;
        let mut path = self.explorer.root().to_path_buf();
        for name in &parts[..parts.len() - 1] {
            path.push(OsStr::from_bytes(name));
            let m = self.filesystem.metadata(&path)?;
            if m.kind != Kind::Dir || !self.eligible(&m) {
                return Err(invalid("destination ancestry is excluded"));
            }
            self.work.nodes_examined += self.explorer.child_ids(parent).len();
            let existing = self
                .explorer
                .child_ids(parent)
                .iter()
                .copied()
                .find(|&child| self.explorer.map.basename(child as usize) == *name);
            parent = if let Some(child) = existing {
                if identity(&self.explorer.map.nodes[child as usize]) != m.identity {
                    return Err(invalid("destination parent changed; refresh it explicitly"));
                }
                child
            } else {
                self.issue(
                    "new destination ancestor has unscanned children; refresh it explicitly",
                );
                self.append(parent, name, &m)?
            };
            if parent == id {
                return Err(invalid("destination would create an inventory cycle"));
            }
        }
        let name = parts.last().unwrap();
        let old_parent = self.explorer.map.nodes[id as usize].parent;
        // A saved occupant is now stale; Foundation returned the validated moved inode.
        let collision = self
            .explorer
            .child_ids(parent)
            .iter()
            .copied()
            .find(|&child| child != id && self.explorer.map.basename(child as usize) == *name);
        if let Some(other) = collision {
            self.remove_node(other);
        }
        let bytes = self.explorer.map.nodes[id as usize].subtree;
        self.delta(old_parent, -i128::from(bytes));
        let mut children = self.explorer.child_ids(old_parent).to_vec();
        self.work.child_ids_copied += children.len();
        children.retain(|&child| child != id);
        self.explorer.replace_children(old_parent, children);
        let n = &mut self.explorer.map.nodes[id as usize];
        n.parent = parent;
        n.name_offset = self.explorer.map.names.len() as u64;
        n.name_len = name.len() as u32;
        self.explorer.map.names.extend_from_slice(name);
        let mut children = self.explorer.child_ids(parent).to_vec();
        self.work.child_ids_copied += children.len();
        children.push(id);
        self.explorer.replace_children(parent, children);
        self.sort.insert(parent);
        self.delta(parent, i128::from(bytes));
        let mut pending = vec![id];
        while let Some(child) = pending.pop() {
            self.work.nodes_examined += 1;
            let n = &self.explorer.map.nodes[child as usize];
            if n.kind == Kind::File {
                self.groups.insert(identity(n));
            }
            self.work.child_ids_copied += self.explorer.child_ids(child).len();
            pending.extend_from_slice(self.explorer.child_ids(child));
        }
        self.set_metadata(id, &moved);
        self.refresh_own(old_parent);
        if parent != old_parent {
            self.refresh_own(parent);
        }
        Ok(())
    }
}
