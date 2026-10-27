//! Darwin SDK getattrlistbulk(2), getattrlist(2), attr.h: fields are packed at
//! four-byte alignment, even u64. Never cast returned records to Rust structs.
use crate::{Entry, Kind, invalid};
use libc::*;
use std::os::unix::ffi::OsStringExt;
use std::{collections::HashSet, fs::File, io, os::fd::AsRawFd, path::PathBuf};

// Present in SDK attr.h/stat.h, absent in libc 0.2.186.
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
pub const SF_FIRMLINK: u32 = 0x0080_0000;
const COMMON: u32 = ATTR_CMN_RETURNED_ATTRS
    | ATTR_CMN_ERROR
    | ATTR_CMN_NAME
    | ATTR_CMN_DEVID
    | ATTR_CMN_OBJTYPE
    | ATTR_CMN_FLAGS
    | ATTR_CMN_FILEID;
const DIR: u32 = ATTR_DIR_MOUNTSTATUS | ATTR_DIR_ALLOCSIZE;
const FILE: u32 = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE;

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}
impl<'a> Cursor<'a> {
    fn take<const N: usize>(&mut self) -> io::Result<[u8; N]> {
        let end = self
            .pos
            .checked_add(N)
            .ok_or_else(|| invalid("offset overflow"))?;
        let bytes = self
            .bytes
            .get(self.pos..end)
            .ok_or_else(|| invalid("truncated attribute"))?;
        self.pos = end;
        Ok(bytes.try_into().unwrap())
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_ne_bytes(self.take()?))
    }
    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_ne_bytes(self.take()?))
    }
}

pub struct BulkRecord {
    pub name: Vec<u8>,
    pub result: io::Result<Entry>,
}

/// No PACK_INVAL_ATTRS: consume only returned bits, and require every field used.
/// A missing directory allocation is the sole supported metadata fallback.
pub fn parse_record(bytes: &[u8]) -> io::Result<BulkRecord> {
    let mut c = Cursor { bytes, pos: 0 };
    if c.u32()? as usize != bytes.len() || !bytes.len().is_multiple_of(8) {
        return Err(invalid("invalid bulk record length/alignment"));
    }
    let common = c.u32()?;
    let vol = c.u32()?;
    let dir = c.u32()?;
    let file = c.u32()?;
    let fork = c.u32()?;
    if common & !COMMON != 0
        || dir & !DIR != 0
        || file & !FILE != 0
        || vol != 0
        || fork != 0
        || common & ATTR_CMN_RETURNED_ATTRS == 0
    {
        return Err(invalid("unexpected returned attribute mask"));
    }
    let error = if common & ATTR_CMN_ERROR != 0 {
        c.u32()?
    } else {
        0
    };
    if common & ATTR_CMN_NAME == 0 {
        return Err(invalid("missing entry name"));
    }
    let reference = c.pos;
    let offset = c.u32()? as i32;
    let length = c.u32()? as usize;
    if offset < 0 || offset % 4 != 0 || length < 2 {
        return Err(invalid("invalid name reference"));
    }
    let start = reference
        .checked_add(offset as usize)
        .ok_or_else(|| invalid("name offset overflow"))?;
    let end = start
        .checked_add(length)
        .ok_or_else(|| invalid("name length overflow"))?;
    let name = bytes
        .get(start..end)
        .ok_or_else(|| invalid("name outside bulk record"))?;
    if name.last() != Some(&0) || !crate::valid_basename(&name[..name.len() - 1]) {
        return Err(invalid("invalid bulk basename"));
    }
    let name = name[..name.len() - 1].to_vec();
    if error != 0 {
        if start < c.pos {
            return Err(invalid("name overlaps fields"));
        }
        return Ok(BulkRecord {
            name,
            result: Err(io::Error::from_raw_os_error(error as i32)),
        });
    }
    let dev = if common & ATTR_CMN_DEVID != 0 {
        Some(c.u32()? as libc::dev_t as u64)
    } else {
        None
    };
    let ty = if common & ATTR_CMN_OBJTYPE != 0 {
        Some(c.u32()?)
    } else {
        None
    };
    let flags = if common & ATTR_CMN_FLAGS != 0 {
        Some(c.u32()?)
    } else {
        None
    };
    let ino = if common & ATTR_CMN_FILEID != 0 {
        Some(c.u64()?)
    } else {
        None
    };
    let mount = if dir & ATTR_DIR_MOUNTSTATUS != 0 {
        Some(c.u32()?)
    } else {
        None
    };
    let dir_alloc = if dir & ATTR_DIR_ALLOCSIZE != 0 {
        Some(c.u64()?)
    } else {
        None
    };
    let links = if file & ATTR_FILE_LINKCOUNT != 0 {
        Some(c.u32()?)
    } else {
        None
    };
    let file_alloc = if file & ATTR_FILE_ALLOCSIZE != 0 {
        Some(c.u64()?)
    } else {
        None
    };
    if start < c.pos {
        return Err(invalid("name overlaps fixed attributes"));
    }
    let result = (|| {
        // Error bit may be absent on successful entries (SDK example allows it).
        let ty = ty.ok_or_else(|| invalid("missing object type"))?;
        let kind = match ty {
            1 => Kind::File,
            2 => Kind::Dir,
            5 => Kind::Symlink,
            _ => Kind::Other,
        };
        // lstat specifies most symlink fields as undefined; never use them.
        if kind == Kind::Symlink {
            return Ok(Entry::symlink());
        }
        let dev = dev.ok_or_else(|| invalid("missing device"))?;
        let ino = ino.ok_or_else(|| invalid("missing inode"))?;
        let flags = flags.ok_or_else(|| invalid("missing flags"))?;
        let (allocation, links, mount) = if kind == Kind::Dir {
            (
                dir_alloc,
                1,
                mount.ok_or_else(|| invalid("missing mount status"))?,
            )
        } else {
            (
                Some(file_alloc.ok_or_else(|| invalid("missing file allocation"))?),
                links.ok_or_else(|| invalid("missing link count"))?,
                0,
            )
        };
        if allocation.is_some_and(|v| v > i64::MAX as u64) {
            return Err(invalid("negative allocation"));
        }
        Ok(Entry {
            kind,
            dev,
            ino,
            flags,
            links,
            allocation,
            mount,
        })
    })();
    Ok(BulkRecord { name, result })
}

pub fn parse_batch(
    bytes: &[u8],
    count: usize,
    mut visit: impl FnMut(BulkRecord),
) -> io::Result<()> {
    parse_batch_fallible(bytes, count, |record| {
        visit(record);
        Ok(())
    })
}
fn parse_batch_fallible(
    bytes: &[u8],
    count: usize,
    mut visit: impl FnMut(BulkRecord) -> io::Result<()>,
) -> io::Result<()> {
    let mut pos = 0usize;
    for _ in 0..count {
        let head = bytes
            .get(
                pos..pos
                    .checked_add(4)
                    .ok_or_else(|| invalid("batch overflow"))?,
            )
            .ok_or_else(|| invalid("truncated bulk length"))?;
        let len = u32::from_ne_bytes(head.try_into().unwrap()) as usize;
        if len < 24 {
            return Err(invalid("short bulk record"));
        }
        let end = pos
            .checked_add(len)
            .ok_or_else(|| invalid("batch length overflow"))?;
        visit(parse_record(
            bytes
                .get(pos..end)
                .ok_or_else(|| invalid("truncated bulk record"))?,
        )?)?;
        pos = end;
    }
    Ok(())
}

pub fn enumerate(dir: &File, mut visit: impl FnMut(BulkRecord)) -> io::Result<()> {
    enumerate_controlled(
        dir,
        |record| {
            visit(record);
            Ok(())
        },
        None,
    )
}
pub(crate) fn enumerate_controlled(
    dir: &File,
    mut visit: impl FnMut(BulkRecord) -> io::Result<()>,
    control: Option<&crate::scan_control::ScanControl>,
) -> io::Result<()> {
    let mut attrs = attrlist {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: COMMON,
        volattr: 0,
        dirattr: DIR,
        fileattr: FILE,
        forkattr: 0,
    };
    // u64 storage guarantees the eight-byte record alignment required by bulk.
    let mut storage = vec![0u64; 32 * 1024];
    loop {
        crate::scan_control::check(control)?;
        // SAFETY: valid directory fd, initialized attrlist, writable aligned buffer.
        let count = unsafe {
            getattrlistbulk(
                dir.as_raw_fd(),
                (&mut attrs as *mut attrlist).cast(),
                storage.as_mut_ptr().cast(),
                storage.len() * 8,
                0,
            )
        };
        crate::scan_control::check(control)?;
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        if count == 0 {
            return Ok(());
        }
        // SAFETY: byte view of initialized u64 storage; retained only during this call.
        let bytes =
            unsafe { std::slice::from_raw_parts(storage.as_ptr().cast::<u8>(), storage.len() * 8) };
        parse_batch_fallible(bytes, count as usize, &mut visit)?;
    }
}

pub fn mount_paths() -> io::Result<HashSet<PathBuf>> {
    for _ in 0..3 {
        // SAFETY: null/zero asks only for count.
        let count = unsafe { getfsstat(std::ptr::null_mut(), 0, MNT_NOWAIT) };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        let capacity = count as usize + 16;
        let size = capacity
            .checked_mul(std::mem::size_of::<statfs>())
            .and_then(|v| i32::try_from(v).ok())
            .ok_or_else(|| invalid("mount table too large"))?;
        // SAFETY: zero is valid storage for statfs, kernel writes at most size bytes.
        let mut entries: Vec<statfs> = (0..capacity)
            .map(|_| unsafe { std::mem::zeroed() })
            .collect();
        let actual = unsafe { getfsstat(entries.as_mut_ptr(), size, MNT_NOWAIT) };
        if actual < 0 {
            return Err(io::Error::last_os_error());
        }
        if actual as usize >= capacity {
            continue;
        }
        return entries[..actual as usize]
            .iter()
            .map(|entry| {
                let bytes: Vec<u8> = entry.f_mntonname.iter().map(|v| *v as u8).collect();
                let end = bytes
                    .iter()
                    .position(|b| *b == 0)
                    .ok_or_else(|| invalid("unterminated mount path"))?;
                Ok(PathBuf::from(std::ffi::OsString::from_vec(
                    bytes[..end].to_vec(),
                )))
            })
            .collect();
    }
    Err(invalid("mount table changing during scan setup"))
}

pub fn peak_rss() -> io::Result<u64> {
    // SAFETY: valid writable rusage; only read after successful call. Darwin reports bytes.
    let mut usage: rusage = unsafe { std::mem::zeroed() };
    if unsafe { getrusage(RUSAGE_SELF, &mut usage) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(usage.ru_maxrss as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record() -> Vec<u8> {
        let mut b = Vec::new();
        for v in [80u32, COMMON, 0, 0, FILE, 0, 0, 44, 2, 1, 1, 0] {
            b.extend(v.to_ne_bytes());
        }
        b.extend(42u64.to_ne_bytes());
        b.extend(1u32.to_ne_bytes());
        b.extend(4096u64.to_ne_bytes());
        b.extend([0u8; 4]);
        b.extend(b"x\0");
        b.resize(80, 0);
        b
    }
    #[test]
    fn bulk_parser_requires_mount_status_but_allows_directory_allocation_fallback() {
        let mut bytes = Vec::new();
        for value in [
            64u32,
            COMMON,
            0,
            ATTR_DIR_MOUNTSTATUS,
            0,
            0,
            0,
            32,
            2,
            1,
            2,
            0,
        ] {
            bytes.extend(value.to_ne_bytes());
        }
        bytes.extend(42u64.to_ne_bytes());
        bytes.extend(0u32.to_ne_bytes());
        bytes.extend(b"d\0");
        bytes.resize(64, 0);
        let entry = parse_record(&bytes).unwrap().result.unwrap();
        assert_eq!(entry.kind, Kind::Dir);
        assert_eq!(entry.allocation, None);
        bytes[12..16].copy_from_slice(&0u32.to_ne_bytes());
        assert!(parse_record(&bytes).unwrap().result.is_err());
    }
    #[test]
    fn bulk_parser_preserves_non_utf8_bytes() {
        let mut bytes = record();
        bytes[72] = 0xff;
        assert_eq!(parse_record(&bytes).unwrap().name, vec![0xff]);
    }
    #[test]
    fn bulk_parser_rejects_truncation_and_malformed_fields() {
        let good = record();
        assert_eq!(
            parse_record(&good).unwrap().result.unwrap().allocation,
            Some(4096)
        );
        for len in 0..good.len() {
            assert!(parse_record(&good[..len]).is_err());
        }
        for (at, value) in [
            (0, 0),
            (4, 0),
            (8, 1),
            (28, u32::MAX),
            (28, 0),
            (32, u32::MAX),
        ] {
            let mut bad = good.clone();
            bad[at..at + 4].copy_from_slice(&value.to_ne_bytes());
            assert!(parse_record(&bad).is_err());
        }
        assert!(parse_batch(&good, 2, |_| {}).is_err());
        let mut missing = good.clone();
        missing[16..20].copy_from_slice(&ATTR_FILE_LINKCOUNT.to_ne_bytes());
        assert!(parse_record(&missing).unwrap().result.is_err());
        // Arbitrary input must never panic, including length/offset overflows.
        let mut seed = 7u64;
        for len in 0..512 {
            let mut b = vec![0; len];
            for byte in &mut b {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                *byte = (seed >> 32) as u8;
            }
            let _ = parse_batch(&b, 3, |_| {});
        }
    }
}
