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
#[derive(Clone, Copy)]
pub(super) struct FileObservation {
    allocation: u64,
    links: u32,
    conflicting: bool,
}
impl FileObservation {
    fn new(m: &ScanMetadata) -> Self {
        Self {
            allocation: m.allocated_bytes,
            links: m.links,
            conflicting: false,
        }
    }
}
/// Live reads of one controlled refresh, made before its commit point. The in-memory update
/// answers from them, so a Stop during the reads changes nothing. A request that the read did
/// not make falls back to the filesystem, as an uncontrolled refresh does.
#[derive(Default)]
pub(super) struct LiveSubtree {
    metadata: HashMap<PathBuf, Result<LiveMetadata, LiveError>>,
    directories: HashMap<PathBuf, Result<Vec<DirectoryEntry>, LiveError>>,
}
/// An I/O error kept with its kind and message, so `refresh_target` sees the same error.
#[derive(Clone)]
pub(super) struct LiveError(io::ErrorKind, String);
impl From<io::Error> for LiveError {
    fn from(e: io::Error) -> Self {
        Self(e.kind(), e.to_string())
    }
}
impl From<LiveError> for io::Error {
    fn from(e: LiveError) -> Self {
        io::Error::new(e.0, e.1)
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
    fn capture_baseline(&mut self, key: Identity) {
        if self.baselines.contains_key(&key) {
            return;
        }
        let mut allocation = None;
        if !self.unresolved_groups.contains(&key) {
            // Capture before the first append/removal/update, including overlay
            // members. A known zero is Some(0), not an unknown observation.
            for id in self.members(key) {
                self.work.identity_members += 1;
                let node = &self.explorer.map.nodes[id as usize];
                if node.kind == Kind::File {
                    allocation = Some(node.raw);
                    break;
                }
            }
        }
        self.baselines.insert(key, allocation);
    }
    fn observe_file(&mut self, m: &ScanMetadata) {
        let previous = self
            .observations
            .entry(m.identity)
            .or_insert_with(|| FileObservation::new(m));
        if previous.allocation != m.allocated_bytes {
            previous.conflicting = true;
        } else {
            previous.links = m.links;
        }
        // Recovery cannot depend on raw-value change detection: an unknown group
        // may become consistent at a value already stored on one or all aliases.
        if self.unresolved_groups.contains(&m.identity) {
            self.capture_baseline(m.identity);
            self.groups.insert(m.identity);
        }
    }
    pub(super) fn reaccount(&mut self) {
        for key in std::mem::take(&mut self.groups) {
            let members = self.members(key);
            if members.is_empty() {
                self.unresolved_groups.remove(&key);
                continue;
            }
            let conflicting = self.observations.get(&key).is_some_and(|m| m.conflicting);
            // One post-removal alias cannot resolve contradictory observations
            // from the same refresh. Nonconflicting survivor freshness is unchanged.
            if self.survivor_groups.contains(&key) && !conflicting {
                // A removed directory's old descendant allocation is not evidence
                // of the current size of its aliases elsewhere in scope.
                if let Some(&survivor) = members.first() {
                    self.work.identity_members += 1;
                    match self.validate(&self.target(survivor)) {
                        Ok(m) => {
                            self.observations
                                .insert(key, FileObservation::new(&ScanMetadata::from(&m)));
                        }
                        Err(e) => {
                            self.observations.remove(&key);
                            self.issue(format!("surviving hardlink observation failed: {e}"));
                        }
                    }
                }
            }
            let observation = self
                .observations
                .get(&key)
                .filter(|m| !m.conflicting)
                .copied();
            let baseline = self.baselines.get(&key).copied();
            let allocation = observation.map(|m| m.allocation).or(baseline.flatten());
            let unattributed = observation.is_none()
                && (self.unresolved_groups.contains(&key) || baseline == Some(None));
            if observation.is_some() {
                self.unresolved_groups.remove(&key);
            } else if unattributed {
                self.unresolved_groups.insert(key);
                self.issue(if conflicting {
                    "conflicting allocation observations for one inode; no prior allocation; group left unattributed"
                } else {
                    "no prior allocation after failed observation; group left unattributed"
                });
            } else if conflicting {
                self.issue("conflicting allocation observations for one inode; previous recorded allocation retained");
            }
            let mut owner = None;
            let mut owner_path = Vec::new();
            for &id in &members {
                self.work.identity_members += 1;
                let n = &mut self.explorer.map.nodes[id as usize];
                if n.kind != Kind::File {
                    continue;
                }
                if let Some(allocation) = allocation {
                    if n.raw != allocation {
                        self.state.dirty = true;
                    }
                    n.raw = allocation;
                }
                if let Some(m) = observation {
                    if n.links != m.links {
                        self.state.dirty = true;
                    }
                    n.links = m.links;
                }
                let path = self.explorer.map.relative_path(id as usize);
                if owner.is_none() || path < owner_path {
                    owner = Some(id);
                    owner_path = path;
                }
            }
            // Subtract old ownership before adding a new owner, avoiding transient overflow.
            for &id in &members {
                self.work.identity_members += 1;
                if self.explorer.map.nodes[id as usize].kind == Kind::File && Some(id) != owner {
                    self.accounted(id, 0);
                }
            }
            if let Some(id) = owner {
                self.work.identity_members += 1;
                self.accounted(
                    id,
                    if unattributed {
                        0
                    } else {
                        self.explorer.map.nodes[id as usize].raw
                    },
                );
            }
        }
        // These are operation-local observations, not another retained inode index.
        self.observations = HashMap::new();
        self.baselines = HashMap::new();
        self.survivor_groups = HashSet::new();
    }
    pub(super) fn set_metadata(&mut self, id: u32, m: &ScanMetadata) {
        self.work.nodes_examined += 1;
        if m.kind == Kind::File {
            self.observe_file(m);
        }
        let changed = {
            let n = &self.explorer.map.nodes[id as usize];
            n.raw != m.allocated_bytes || (m.kind == Kind::File && n.links != m.links)
        };
        if !changed {
            return;
        }
        self.state.dirty = true;
        if m.kind == Kind::File {
            self.capture_baseline(m.identity);
            self.groups.insert(m.identity);
        } else {
            self.explorer.map.nodes[id as usize].raw = m.allocated_bytes;
            self.accounted(id, m.allocated_bytes);
        }
    }
    fn append(&mut self, parent: u32, name: &[u8], m: &ScanMetadata) -> io::Result<u32> {
        self.append_entry(parent, name, m, true)
    }
    fn append_entry(
        &mut self,
        parent: u32,
        name: &[u8],
        m: &ScanMetadata,
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
        if m.kind == Kind::File {
            self.capture_baseline(m.identity);
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
            // Stage once per identity; resolve even original links=1 aliases at finish.
            self.observe_file(m);
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
            let n = &self.explorer.map.nodes[id as usize];
            if n.kind == Kind::File {
                let key = identity(n);
                self.capture_baseline(key);
                self.groups.insert(key);
                self.survivor_groups.insert(key);
            }
            let n = &mut self.explorer.map.nodes[id as usize];
            n.accounted = 0;
            n.subtree = 0;
            self.explorer.invalidate(id);
        }
        self.state.dirty = true;
    }
    fn eligible(&self, m: &ScanMetadata) -> bool {
        m.kind != Kind::Symlink
            && m.identity.device == self.explorer.map.nodes[0].dev
            && !m.mount
            && m.flags & crate::native::SF_FIRMLINK == 0
            && Some(m.identity) != self.filesystem.snapshot_identity()
    }
    /// Reads the live subtree of a controlled refresh, as `refresh_target` will ask for it,
    /// without changing the inventory. Stop is checked before every metadata request.
    pub(super) fn read_live_subtree(
        &mut self,
        id: u32,
        control: &ScanControl,
    ) -> io::Result<LiveSubtree> {
        let mut live = LiveSubtree::default();
        let mut pending = vec![self.target(id).path];
        let mut seen = HashSet::new();
        while let Some(path) = pending.pop() {
            control.check()?;
            let m = self.filesystem.metadata(&path);
            control.examined(1);
            let directory = match &m {
                Ok(m)
                    if m.kind == Kind::Dir
                        && self.eligible(&ScanMetadata::from(m))
                        && seen.insert(m.identity) =>
                {
                    Some(Target {
                        path: path.clone(),
                        identity: m.identity,
                        kind: m.kind,
                    })
                }
                _ => None,
            };
            live.metadata
                .insert(path.clone(), m.map_err(LiveError::from));
            let Some(target) = directory else { continue };
            control.check()?;
            let entries = self.filesystem.read_directory(&target);
            if let Ok(entries) = &entries {
                control.examined(entries.len());
                for e in entries {
                    if e.metadata.kind == Kind::Dir
                        && self.eligible(&e.metadata)
                        && crate::valid_basename(&e.name)
                    {
                        pending.push(path.join(OsStr::from_bytes(&e.name)));
                    }
                }
            }
            live.directories
                .insert(path, entries.map_err(LiveError::from));
        }
        Ok(live)
    }
    fn refresh_metadata(&mut self, path: &Path) -> io::Result<LiveMetadata> {
        match self.prefetched.as_ref().and_then(|l| l.metadata.get(path)) {
            Some(read) => read.clone().map_err(io::Error::from),
            None => self.filesystem.metadata(path),
        }
    }
    fn refresh_entries(&mut self, target: &Target) -> io::Result<Vec<DirectoryEntry>> {
        match self
            .prefetched
            .as_mut()
            .and_then(|l| l.directories.remove(&target.path))
        {
            Some(read) => read.map_err(io::Error::from),
            None => self.filesystem.read_directory(target),
        }
    }
    pub(super) fn refresh_own(&mut self, id: u32) {
        match self.validate(&self.target(id)) {
            Ok(m) => self.set_metadata(id, &ScanMetadata::from(&m)),
            Err(e) => self.issue(e),
        }
    }
    pub(super) fn refresh_target(&mut self, id: u32) {
        let mut pending = vec![id];
        let mut seen = HashSet::new();
        while let Some(id) = pending.pop() {
            let target = self.target(id);
            let m = match self.refresh_metadata(&target.path) {
                Ok(m) => ScanMetadata::from(&m),
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
            let entries = match self.refresh_entries(&target) {
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
        let moved = ScanMetadata::from(&self.filesystem.metadata(destination)?);
        if moved.identity != target.identity || moved.kind != target.kind {
            return Err(invalid("Trash destination identity changed"));
        }
        let mut parent = 0;
        let mut path = self.explorer.root().to_path_buf();
        for name in &parts[..parts.len() - 1] {
            path.push(OsStr::from_bytes(name));
            let m = ScanMetadata::from(&self.filesystem.metadata(&path)?);
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
