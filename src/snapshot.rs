//! Version 1: explicit little endian integers, no native struct dumps.
use crate::{Counters, Kind, Map, Node, invalid, valid_basename};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufWriter, Write},
    os::unix::{
        ffi::{OsStrExt, OsStringExt},
        fs::OpenOptionsExt,
    },
    path::Path,
};
const MAGIC: &[u8; 8] = b"DMAPBEN1";
const HEADER: usize = 104;
const RECORD: usize = 72;
const SEED: u64 = 0xcbf29ce484222325;
fn hash(mut state: u64, bytes: &[u8]) -> u64 {
    for byte in bytes {
        state ^= *byte as u64;
        state = state.wrapping_mul(0x100000001b3);
    }
    state
}
struct Writer<W> {
    out: W,
    checksum: u64,
}
impl<W: Write> Writer<W> {
    fn bytes(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.out.write_all(bytes)?;
        self.checksum = hash(self.checksum, bytes);
        Ok(())
    }
    fn u32(&mut self, n: u32) -> io::Result<()> {
        self.bytes(&n.to_le_bytes())
    }
    fn u64(&mut self, n: u64) -> io::Result<()> {
        self.bytes(&n.to_le_bytes())
    }
}
pub fn save(map: &Map, path: &Path) -> io::Result<()> {
    publish(map, path, false, None)
}

/// Publish without replacing even a concurrently created destination.
pub fn save_new(map: &Map, path: &Path) -> io::Result<()> {
    publish(map, path, true, None)
}

pub(crate) fn save_new_controlled(
    map: &Map,
    path: &Path,
    control: &crate::scan_control::ScanControl,
) -> io::Result<()> {
    publish(map, path, true, Some(control))
}

fn publish(
    map: &Map,
    path: &Path,
    create_new: bool,
    control: Option<&crate::scan_control::ScanControl>,
) -> io::Result<()> {
    crate::scan_control::check(control)?;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    // create_new prevents collisions/symlink clobbering; rename replaces the destination
    // only after flush+fsync. Snapshot directories must be trusted by the caller.
    let mut temporary = None;
    for suffix in 0..100 {
        let candidate = parent.join(format!(
            ".disk-map-bench-{}-{suffix}.tmp",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(file) => {
                temporary = Some((candidate, file));
                break;
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    let (temporary, file) =
        temporary.ok_or_else(|| invalid("snapshot temporary names occupied"))?;
    let result = (|| {
        let mut w = Writer {
            out: BufWriter::new(file),
            checksum: SEED,
        };
        w.bytes(MAGIC)?;
        w.u32(1)?;
        w.u32(RECORD as u32)?;
        w.u64(map.nodes.len() as u64)?;
        w.u64(map.names.len() as u64)?;
        let root = map.root.as_os_str().as_bytes();
        w.u64(root.len() as u64)?;
        let c = &map.counters;
        for v in [
            c.symlinks,
            c.mounts,
            c.firmlinks,
            c.errors,
            c.metadata_fallbacks,
            c.root_fstats,
            c.directory_fstats,
            c.duplicate_dirs,
        ] {
            w.u64(v)?;
        }
        w.bytes(root)?;
        for (id, n) in map.nodes.iter().enumerate() {
            if id % 256 == 0 {
                crate::scan_control::check(control)?;
            }
            w.u32(n.parent)?;
            w.u32(n.name_len)?;
            w.u64(n.name_offset)?;
            for v in [n.dev, n.ino, n.raw, n.accounted, n.subtree] {
                w.u64(v)?;
            }
            w.u32(n.links)?;
            w.u32(n.kind as u32)?;
            // Reserved for format evolution, must remain zero.
            w.u64(0)?;
        }
        for chunk in map.names.chunks(64 * 1024) {
            crate::scan_control::check(control)?;
            w.bytes(chunk)?;
        }
        w.out.write_all(&w.checksum.to_le_bytes())?;
        crate::scan_control::check(control)?;
        w.out.flush()?;
        crate::scan_control::check(control)?;
        w.out.get_ref().sync_all()?;
        if let Some(control) = control {
            control.commit()?;
        }
        if create_new {
            // Same-directory hard link is atomic and fails if any destination exists.
            fs::hard_link(&temporary, path)?;
            if let Some(control) = control {
                control.published();
            }
            fs::remove_file(&temporary)?;
        } else {
            fs::rename(&temporary, path)?;
            if let Some(control) = control {
                control.published();
            }
        }
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}
impl Reader<'_> {
    fn bytes(&mut self, len: usize) -> io::Result<&[u8]> {
        let end = self
            .pos
            .checked_add(len)
            .ok_or_else(|| invalid("snapshot offset overflow"))?;
        let b = self
            .bytes
            .get(self.pos..end)
            .ok_or_else(|| invalid("truncated snapshot"))?;
        self.pos = end;
        Ok(b)
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.bytes(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.bytes(8)?.try_into().unwrap()))
    }
    fn size(&mut self) -> io::Result<usize> {
        usize::try_from(self.u64()?).map_err(|_| invalid("snapshot size overflow"))
    }
}
pub fn load(path: &Path) -> io::Result<Map> {
    decode(&fs::read(path)?)
}
pub fn decode(bytes: &[u8]) -> io::Result<Map> {
    if bytes.len() < HEADER + 8 {
        return Err(invalid("short snapshot header"));
    }
    let payload = bytes.len() - 8;
    if hash(SEED, &bytes[..payload]) != u64::from_le_bytes(bytes[payload..].try_into().unwrap()) {
        return Err(invalid("snapshot checksum mismatch"));
    }
    let mut r = Reader {
        bytes: &bytes[..payload],
        pos: 0,
    };
    if r.bytes(8)? != MAGIC || r.u32()? != 1 || r.u32()? != RECORD as u32 {
        return Err(invalid("unsupported snapshot format"));
    }
    let count = r.size()?;
    let names_len = r.size()?;
    let root_len = r.size()?;
    let expected = count
        .checked_mul(RECORD)
        .and_then(|n| n.checked_add(HEADER))
        .and_then(|n| n.checked_add(root_len))
        .and_then(|n| n.checked_add(names_len));
    if count == 0 || count > u32::MAX as usize || expected != Some(payload) {
        return Err(invalid("invalid snapshot dimensions"));
    }
    let counters = Counters {
        symlinks: r.u64()?,
        mounts: r.u64()?,
        firmlinks: r.u64()?,
        errors: r.u64()?,
        metadata_fallbacks: r.u64()?,
        root_fstats: r.u64()?,
        directory_fstats: r.u64()?,
        duplicate_dirs: r.u64()?,
    };
    let root = r.bytes(root_len)?;
    if root.first() != Some(&b'/') || root.contains(&0) {
        return Err(invalid("invalid snapshot root"));
    }
    let root = std::path::PathBuf::from(std::ffi::OsString::from_vec(root.to_vec()));
    let mut nodes: Vec<Node> = Vec::with_capacity(count);
    let mut expected_offset = 0u64;
    for id in 0..count {
        let parent = r.u32()?;
        let name_len = r.u32()?;
        let name_offset = r.u64()?;
        let dev = r.u64()?;
        let ino = r.u64()?;
        let raw = r.u64()?;
        let accounted = r.u64()?;
        let subtree = r.u64()?;
        let links = r.u32()?;
        let kind = match r.u32()? {
            1 => Kind::File,
            2 => Kind::Dir,
            3 => Kind::Other,
            _ => return Err(invalid("invalid snapshot kind")),
        };
        if r.u64()? != 0 || raw > i64::MAX as u64 {
            return Err(invalid("invalid node reserved/allocation field"));
        }
        if id == 0 {
            if parent != 0 || name_len != 0 || kind != Kind::Dir {
                return Err(invalid("invalid root node"));
            }
        } else if parent as usize >= id
            || nodes[parent as usize].kind != Kind::Dir
            || name_len == 0
            || dev != nodes[0].dev
        {
            return Err(invalid("invalid parent/device/name"));
        }
        if name_offset != expected_offset {
            return Err(invalid("noncanonical name offset"));
        }
        expected_offset = expected_offset
            .checked_add(name_len as u64)
            .ok_or_else(|| invalid("name arena overflow"))?;
        if expected_offset > names_len as u64 {
            return Err(invalid("name outside arena"));
        }
        nodes.push(Node {
            parent,
            name_len,
            name_offset,
            dev,
            ino,
            raw,
            accounted,
            subtree,
            links,
            kind,
        });
    }
    if expected_offset != names_len as u64 {
        return Err(invalid("unused name arena bytes"));
    }
    let names = r.bytes(names_len)?.to_vec();
    let mut map = Map {
        root,
        nodes,
        names,
        counters,
        error_samples: Vec::new(),
    };
    let mut siblings = std::collections::HashSet::new();
    let mut directories = std::collections::HashSet::new();
    for (id, n) in map.nodes.iter().enumerate() {
        if id != 0
            && (!valid_basename(map.basename(id)) || !siblings.insert((n.parent, map.basename(id))))
        {
            return Err(invalid("invalid/duplicate snapshot basename"));
        }
        if n.kind == Kind::Dir && !directories.insert((n.dev, n.ino)) {
            return Err(invalid("duplicate directory identity"));
        }
    }
    drop(siblings);
    drop(directories);
    let stored: Vec<_> = map.nodes.iter().map(|n| (n.accounted, n.subtree)).collect();
    map.aggregate()?;
    if map
        .nodes
        .iter()
        .zip(stored)
        .any(|(n, (accounted, subtree))| (n.accounted, n.subtree) != (accounted, subtree))
    {
        return Err(invalid("invalid snapshot accounting"));
    }
    Ok(map)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshot_preserves_non_utf8_bytes() {
        let mut map = Map {
            root: "/fixture".into(),
            nodes: vec![],
            names: vec![],
            counters: Counters::default(),
            error_samples: vec![],
        };
        for (name, kind, ino) in [
            (b"".as_slice(), Kind::Dir, 1),
            (b"raw-\xff\n".as_slice(), Kind::File, 2),
        ] {
            map.add(
                0,
                name,
                crate::Entry {
                    kind,
                    dev: 1,
                    ino,
                    flags: 0,
                    links: 1,
                    allocation: Some(512),
                    mount: 0,
                },
            )
            .unwrap();
        }
        map.aggregate().unwrap();
        let directory =
            Path::new("/private/tmp").join(format!("disk-map-raw-unit-{}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("snapshot.bin");
        save(&map, &path).unwrap();
        let loaded = load(&path).unwrap();
        fs::remove_dir_all(directory).unwrap();
        assert_eq!(loaded.canonical(), map.canonical());
    }
    #[test]
    fn snapshot_rejects_corrupt_structure_with_valid_checksum() {
        let mut map = Map {
            root: "/fixture".into(),
            nodes: vec![],
            names: vec![],
            counters: Counters::default(),
            error_samples: vec![],
        };
        map.add(
            0,
            b"",
            crate::Entry {
                kind: Kind::Dir,
                dev: 1,
                ino: 1,
                flags: 0,
                links: 1,
                allocation: Some(0),
                mount: 0,
            },
        )
        .unwrap();
        let directory = Path::new("/private/tmp")
            .join(format!("disk-map-snapshot-unit-{}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("snapshot.bin");
        save(&map, &path).unwrap();
        let good = fs::read(&path).unwrap();
        fs::remove_dir_all(directory).unwrap();
        assert!(decode(&good).is_ok());
        for len in 0..good.len() {
            assert!(decode(&good[..len]).is_err());
        }
        for at in [
            8usize,
            12,
            16,
            24,
            32,
            HEADER + 8,
            HEADER + 8 + 8,
            HEADER + 8 + 40,
            HEADER + 8 + 60,
            HEADER + 8 + 64,
        ] {
            let mut bad = good.clone();
            bad[at] ^= 0xff;
            let end = bad.len() - 8;
            let checksum = hash(SEED, &bad[..end]);
            bad[end..].copy_from_slice(&checksum.to_le_bytes());
            assert!(decode(&bad).is_err(), "offset {at}");
        }
        let mut bad = good;
        bad[50] ^= 1;
        assert!(decode(&bad).is_err());
    }
}
