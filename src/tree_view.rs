//! Sparse expansion state over the saved child index, with virtual row addressing.
use crate::{
    Kind,
    explorer::{EntryHandle, EntrySummary, Explorer},
    invalid,
};
use std::{
    collections::{BTreeMap, HashMap},
    io,
};

#[derive(Debug)]
struct Branch {
    parent: Option<u32>,
    rank: usize,
    rows: usize,
    children: BTreeMap<usize, u32>,
    // (virtual start row, expanded child ID, cumulative extra rows)
    prefix: Vec<(usize, u32, usize)>,
}
impl Branch {
    fn payload_bytes(&self) -> usize {
        self.prefix.capacity() * std::mem::size_of::<(usize, u32, usize)>()
            + self.children.len() * std::mem::size_of::<(usize, u32)>()
    }
}
#[derive(Debug)]
pub struct TreeView {
    root: EntryHandle,
    branches: HashMap<u32, Branch>,
    // Prefix-vector and child-map payload, maintained only when expansion state changes.
    nested_payload_bytes: usize,
    #[cfg(test)]
    payload_term_reads: std::cell::Cell<usize>,
}
pub struct TreeRow<'a> {
    pub entry: EntrySummary<'a>,
    pub depth: u32,
    pub expanded: bool,
}
pub struct TreePage<'a> {
    pub rows: Vec<TreeRow<'a>>,
    pub total: usize,
    pub visits: usize,
}
impl Explorer {
    fn child_rank(&self, parent: u32, id: u32) -> io::Result<usize> {
        let wanted = &self.map.nodes[id as usize];
        self.child_ids(parent)
            .binary_search_by(|&other| {
                wanted
                    .subtree
                    .cmp(&self.map.nodes[other as usize].subtree)
                    .then_with(|| {
                        self.map
                            .basename(other as usize)
                            .cmp(self.map.basename(id as usize))
                    })
                    .then(other.cmp(&id))
            })
            .map_err(|_| invalid("entry is no longer a child of its saved parent"))
    }
}
impl TreeView {
    pub fn new(e: &Explorer, root: EntryHandle) -> io::Result<Self> {
        let entry = e.entry(root)?;
        if entry.kind != Kind::Dir {
            return Err(invalid("tree root must be a directory"));
        }
        let mut branches = HashMap::new();
        branches.insert(
            root.index(),
            Branch {
                parent: None,
                rank: 0,
                rows: entry.child_count,
                children: BTreeMap::new(),
                prefix: vec![],
            },
        );
        Ok(Self {
            root,
            branches,
            nested_payload_bytes: 0,
            #[cfg(test)]
            payload_term_reads: std::cell::Cell::new(0),
        })
    }
    pub fn root(&self) -> EntryHandle {
        self.root
    }
    pub fn row_count(&self) -> usize {
        self.branches[&self.root.index()].rows
    }
    pub fn expanded_count(&self) -> usize {
        self.branches.len() - 1
    }
    // Instrument actual counted-payload term reads in tests, not elapsed-time thresholds.
    fn read_payload_term(&self, bytes: usize) -> usize {
        #[cfg(test)]
        self.payload_term_reads
            .set(self.payload_term_reads.get() + 1);
        bytes
    }
    pub fn expansion_payload_bytes(&self) -> usize {
        self.branches.capacity() * std::mem::size_of::<(u32, Branch)>()
            + self.read_payload_term(self.nested_payload_bytes)
    }
    fn update(&mut self, e: &Explorer, mut id: u32) -> io::Result<()> {
        loop {
            let children = &self.branches[&id].children;
            let mut extra = 0usize;
            let mut prefix = Vec::with_capacity(children.len());
            for (&rank, &child) in children {
                let start = rank
                    .checked_add(extra)
                    .ok_or_else(|| invalid("tree row count overflow"))?;
                extra = extra
                    .checked_add(self.branches[&child].rows)
                    .ok_or_else(|| invalid("tree row count overflow"))?;
                prefix.push((start, child, extra));
            }
            let b = self.branches.get_mut(&id).unwrap();
            b.rows = e
                .child_ids(id)
                .len()
                .checked_add(extra)
                .ok_or_else(|| invalid("tree row count overflow"))?;
            self.nested_payload_bytes -=
                b.prefix.capacity() * std::mem::size_of::<(usize, u32, usize)>();
            self.nested_payload_bytes +=
                prefix.capacity() * std::mem::size_of::<(usize, u32, usize)>();
            b.prefix = prefix;
            if let Some(parent) = b.parent {
                id = parent;
            } else {
                break;
            }
        }
        Ok(())
    }
    fn remove_branch(&mut self, id: u32) -> Option<Branch> {
        let branch = self.branches.remove(&id)?;
        self.nested_payload_bytes -= branch.payload_bytes();
        Some(branch)
    }
    pub fn expand(&mut self, e: &Explorer, key: EntryHandle, expanded: bool) -> io::Result<()> {
        e.resolve(self.root)?;
        let id = e.resolve(key)?;
        if key == self.root {
            return Ok(());
        }
        if expanded {
            if self.branches.contains_key(&id) {
                return Ok(());
            }
            let entry = e.entry(key)?;
            if entry.kind != Kind::Dir {
                return Err(invalid("only directories expand"));
            }
            let parent = entry
                .parent
                .ok_or_else(|| invalid("entry is outside tree root"))?
                .index();
            if !self.branches.contains_key(&parent) {
                return Err(invalid("expand ancestors before this directory"));
            }
            let rank = e.child_rank(parent, id)?;
            self.branches.insert(
                id,
                Branch {
                    parent: Some(parent),
                    rank,
                    rows: entry.child_count,
                    children: BTreeMap::new(),
                    prefix: vec![],
                },
            );
            self.branches
                .get_mut(&parent)
                .unwrap()
                .children
                .insert(rank, id);
            self.nested_payload_bytes += std::mem::size_of::<(usize, u32)>();
            self.update(e, parent)?;
        } else if let Some(branch) = self.remove_branch(id) {
            let parent = branch.parent.unwrap();
            self.branches
                .get_mut(&parent)
                .unwrap()
                .children
                .remove(&branch.rank);
            self.nested_payload_bytes -= std::mem::size_of::<(usize, u32)>();
            let mut pending: Vec<u32> = branch.children.into_values().collect();
            while let Some(child) = pending.pop() {
                if let Some(b) = self.remove_branch(child) {
                    pending.extend(b.children.into_values());
                }
            }
            self.update(e, parent)?;
        }
        Ok(())
    }
    pub fn rows<'a>(
        &self,
        e: &'a Explorer,
        offset: usize,
        limit: usize,
    ) -> io::Result<TreePage<'a>> {
        e.resolve(self.root)?;
        if !(1..=256).contains(&limit) {
            return Err(invalid("tree row limit must be 1..=256"));
        }
        let mut result = TreePage {
            rows: vec![],
            total: self.row_count(),
            visits: 0,
        };
        for row in offset.min(result.total)..offset.saturating_add(limit).min(result.total) {
            let mut id = self.root.index();
            let mut position = row;
            let mut depth = 0;
            loop {
                result.visits += 1;
                let branch = &self.branches[&id];
                let at = branch
                    .prefix
                    .partition_point(|(start, _, _)| *start <= position);
                let mut extra = 0;
                if at > 0 {
                    let (start, child, cumulative) = branch.prefix[at - 1];
                    if position > start && position <= start + self.branches[&child].rows {
                        id = child;
                        position -= start + 1;
                        depth += 1;
                        continue;
                    }
                    extra = if position == start {
                        cumulative - self.branches[&child].rows
                    } else {
                        cumulative
                    };
                }
                let child = *e
                    .child_ids(id)
                    .get(position - extra)
                    .ok_or_else(|| invalid("stale tree view"))?;
                result.rows.push(TreeRow {
                    entry: e.entry(e.handle(child))?,
                    depth,
                    expanded: self.branches.contains_key(&child),
                });
                break;
            }
        }
        Ok(result)
    }
    /// Read-only position lookup. Hidden/out-of-focus entries and the implicit root have no row.
    /// Ascend expanded ancestors using CSR rank searches and cached prefix counts, not a row scan.
    pub fn visible_row(&self, e: &Explorer, key: EntryHandle) -> io::Result<Option<usize>> {
        let root = e.resolve(self.root)?;
        let mut child = e.resolve(key)?;
        if child == root {
            return Ok(None);
        }
        let mut row = 0;
        loop {
            let parent = e.map.nodes[child as usize].parent;
            let Some(branch) = self.branches.get(&parent) else {
                return Ok(None);
            };
            let rank = e.child_rank(parent, child)?;
            let before = branch
                .prefix
                .partition_point(|(_, id, _)| self.branches[id].rank < rank);
            let extra = if before == 0 {
                0
            } else {
                branch.prefix[before - 1].2
            };
            row += rank + extra;
            if parent == root {
                return Ok(Some(row));
            }
            row += 1;
            child = parent;
        }
    }
    /// Expands only the saved ancestor chain; no sibling enumeration or implicit zoom.
    pub fn reveal(&mut self, e: &Explorer, key: EntryHandle) -> io::Result<usize> {
        let mut id = e.resolve(key)?;
        let root = e.resolve(self.root)?;
        let mut chain = vec![];
        while id != root {
            if id == 0 {
                return Err(invalid("entry is outside tree root"));
            }
            chain.push(id);
            id = e.map.nodes[id as usize].parent;
        }
        if chain.is_empty() {
            return Ok(0);
        }
        // Insert the entire chain before updating counts once, avoiding quadratic
        // ancestor updates on deep reveal. All keys were validated above.
        let mut parent = root;
        for &child in chain.iter().rev().take(chain.len() - 1) {
            if let std::collections::hash_map::Entry::Vacant(slot) = self.branches.entry(child) {
                let rank = e.child_rank(parent, child)?;
                slot.insert(Branch {
                    parent: Some(parent),
                    rank,
                    rows: e.child_ids(child).len(),
                    children: BTreeMap::new(),
                    prefix: vec![],
                });
                self.branches
                    .get_mut(&parent)
                    .unwrap()
                    .children
                    .insert(rank, child);
                self.nested_payload_bytes += std::mem::size_of::<(usize, u32)>();
            }
            parent = child;
        }
        self.update(e, parent)?;
        self.visible_row(e, key)?
            .ok_or_else(|| invalid("revealed entry has no visible row"))
    }
}

#[cfg(test)]
mod tests;
