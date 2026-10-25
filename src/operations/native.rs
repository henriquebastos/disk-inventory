//! macOS adapter. No source content reads; permanent deletion is descriptor-relative.
//! Foundation Trash is path-based and is NOT an atomic inode-conditional move.
use super::*;
use objc2::{
    msg_send,
    rc::{Retained, autoreleasepool},
};
use objc2_foundation::{NSError, NSFileManager, NSURL};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
};

#[derive(Debug)]
pub struct NativePin {
    pub(super) _file: File,
}

pub struct NativeFileSystem {
    snapshot: File,
    identity: Identity,
    root: Identity,
}
impl NativeFileSystem {
    /// Load/pin the same open snapshot inode. Does not check or scan its source root.
    pub fn open_snapshot(path: &Path) -> io::Result<OperationSession<Self>> {
        let mut snapshot = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW_ANY | libc::O_CLOEXEC)
            .open(path)?;
        let m = snapshot.metadata()?;
        if !m.is_file() {
            return Err(invalid("snapshot must be a regular file"));
        }
        let identity = Identity {
            device: m.dev(),
            inode: m.ino(),
        };
        let mut bytes = Vec::new();
        snapshot.read_to_end(&mut bytes)?;
        let map = crate::snapshot::decode(&bytes)?;
        drop(bytes);
        let root = index::identity(&map.nodes[0]);
        Ok(OperationSession::new(
            Explorer::from_map(map)?,
            Self {
                snapshot,
                identity,
                root,
            },
        ))
    }
    fn preflight(&mut self, target: &Target) -> io::Result<()> {
        let mut pending = vec![target.clone()];
        let mut seen = HashSet::new();
        while let Some(t) = pending.pop() {
            let m = self.metadata(&t.path)?;
            check(&m, &t)?;
            if m.identity == self.root
                || m.identity == self.identity
                || m.identity.device != self.root.device
                || m.flags & crate::native::SF_FIRMLINK != 0
            {
                return Err(invalid("native root/snapshot or mount/firmlink protection"));
            }
            if m.kind == Kind::Dir {
                if !seen.insert(m.identity) {
                    return Err(invalid("duplicate directory identity"));
                }
                for entry in self.read_directory(&t)? {
                    if entry.metadata.mount {
                        return Err(invalid("mounted child is protected"));
                    }
                    if entry.metadata.kind != Kind::Symlink {
                        pending.push(Target {
                            path: t.path.join(OsStr::from_bytes(&entry.name)),
                            identity: entry.metadata.identity,
                            kind: entry.metadata.kind,
                        });
                    }
                }
            }
        }
        Ok(())
    }
}
fn c_name(name: &OsStr) -> io::Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| invalid("NUL in path"))
}
fn parent(path: &Path) -> io::Result<(File, CString)> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(invalid("absolute path without '..' required"));
    }
    let name = path
        .file_name()
        .ok_or_else(|| invalid("target needs a basename"))?;
    Ok((
        crate::open_directory(
            path.parent()
                .ok_or_else(|| invalid("target needs a parent"))?,
        )?,
        c_name(name)?,
    ))
}
fn stat_at(dir: &File, name: &CString) -> io::Result<LiveMetadata> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: valid directory descriptor/name and writable stat; no-follow final component.
    if unsafe {
        libc::fstatat(
            dir.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstatat initialized stat on success.
    from_stat(unsafe { stat.assume_init() })
}
fn stat_fd(dir: &File) -> io::Result<LiveMetadata> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: valid descriptor and writable stat.
    if unsafe { libc::fstat(dir.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstat initialized stat on success.
    from_stat(unsafe { stat.assume_init() })
}
fn from_stat(s: libc::stat) -> io::Result<LiveMetadata> {
    let allocated_bytes = u64::try_from(s.st_blocks)
        .ok()
        .and_then(|b| b.checked_mul(512))
        .filter(|&b| b <= i64::MAX as u64)
        .ok_or_else(|| invalid("invalid stat allocation"))?;
    let kind = match s.st_mode & libc::S_IFMT {
        libc::S_IFDIR => Kind::Dir,
        libc::S_IFREG => Kind::File,
        libc::S_IFLNK => Kind::Symlink,
        _ => Kind::Other,
    };
    Ok(LiveMetadata {
        identity: Identity {
            device: s.st_dev as u64,
            inode: s.st_ino,
        },
        kind,
        allocated_bytes,
        logical_bytes: s.st_size.max(0) as u64,
        links: u32::from(s.st_nlink),
        mode: u32::from(s.st_mode),
        modified_seconds: s.st_mtime,
        modified_nanoseconds: s.st_mtime_nsec,
        created_seconds: s.st_birthtime,
        flags: s.st_flags,
        mount: false,
    })
}
fn open_at(dir: &File, name: &CString) -> io::Result<File> {
    // SAFETY: valid descriptor/C string; returned descriptor is owned on success.
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: newly owned descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn check(m: &LiveMetadata, expected: &Target) -> io::Result<()> {
    if m.identity != expected.identity || m.kind != expected.kind || m.kind == Kind::Symlink {
        return Err(invalid("native target identity changed"));
    }
    Ok(())
}
fn enumerate(dir: &File) -> io::Result<Vec<DirectoryEntry>> {
    let mut entries = Vec::new();
    let mut error = None;
    crate::native::enumerate(dir, |record| {
        let result = (|| {
            let e = record.result?;
            // bulk supplies mount/firmlink policy; stat supplies only on-demand fields
            // here because mutation safety also needs precise descendant identities.
            let mut m = stat_at(
                dir,
                &CString::new(record.name.as_slice()).map_err(|_| invalid("invalid child name"))?,
            )?;
            if e.kind != Kind::Symlink
                && (e.dev != m.identity.device || e.ino != m.identity.inode || e.kind != m.kind)
            {
                return Err(invalid("child changed during enumeration"));
            }
            m.mount = e.mount != 0;
            Ok(DirectoryEntry {
                name: record.name,
                metadata: m,
            })
        })();
        match result {
            Ok(entry) => entries.push(entry),
            Err(e) => error = Some(e),
        }
    })?;
    if let Some(error) = error {
        return Err(error);
    }
    Ok(entries)
}
/// Reject known unsupported Foundation representations before any mutation. The
/// published URL helper has a 1024-byte output buffer and warns about non-Unicode.
pub fn validate_trash_path(path: &Path, directory: bool) -> io::Result<()> {
    if !path.is_absolute()
        || path.as_os_str().to_str().is_none()
        || path.as_os_str().as_bytes().len() >= 1024
        || path.as_os_str().as_bytes().contains(&0)
    {
        return Err(invalid(
            "Foundation Trash requires an absolute Unicode path shorter than 1024 bytes",
        ));
    }
    autoreleasepool(|_| {
        let url = if directory {
            NSURL::from_directory_path(path)
        } else {
            NSURL::from_file_path(path)
        }
        .ok_or_else(|| invalid("Foundation URL conversion failed"))?;
        let returned = url
            .to_file_path()
            .ok_or_else(|| invalid("Foundation URL output conversion failed"))?;
        let raw = path.as_os_str().as_bytes();
        let output = returned.as_os_str().as_bytes();
        let directory_slash = directory && output.strip_suffix(b"/") == Some(raw);
        if output != raw && !directory_slash {
            return Err(invalid("Foundation URL did not round-trip raw path"));
        }
        Ok(())
    })
}
impl FileSystem for NativeFileSystem {
    type Pin = NativePin;
    fn pin(&mut self, target: &Target) -> io::Result<Self::Pin> {
        let (parent, name) = parent(&target.path)?;
        // SAFETY: valid parent/name; O_EVTONLY opens metadata/event access, never
        // source contents. O_NOFOLLOW rejects a swapped final symlink.
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_EVTONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: newly owned descriptor.
        let file = unsafe { File::from_raw_fd(fd) };
        check(&stat_fd(&file)?, target)?;
        Ok(NativePin { _file: file })
    }

    fn snapshot_identity(&self) -> Option<Identity> {
        let _pin = &self.snapshot;
        Some(self.identity)
    }
    fn metadata(&mut self, path: &Path) -> io::Result<LiveMetadata> {
        if path == Path::new("/") {
            return stat_fd(&crate::open_directory(path)?);
        }
        let (dir, name) = parent(path)?;
        stat_at(&dir, &name)
    }
    fn read_directory(&mut self, target: &Target) -> io::Result<Vec<DirectoryEntry>> {
        let dir = crate::open_directory(&target.path)?;
        check(&stat_fd(&dir)?, target)?;
        enumerate(&dir)
    }
    fn trash(&mut self, target: &Target, pin: &Self::Pin) -> Mutation {
        if let Err(e) = stat_fd(&pin._file).and_then(|m| check(&m, target)) {
            return Mutation::Failed(e.to_string());
        }
        if let Err(e) = validate_trash_path(&target.path, target.kind == Kind::Dir) {
            return Mutation::Failed(e.to_string());
        }
        // No main-thread Foundation operation: bridges must dispatch to a worker.
        // SAFETY: pthread_main_np takes no arguments and has no preconditions.
        if unsafe { libc::pthread_main_np() } != 0 {
            return Mutation::Failed("Trash must run off the main thread".into());
        }
        let validated = self
            .preflight(target)
            .and_then(|()| self.metadata(&target.path))
            .and_then(|m| {
                check(&m, target)?;
                if Some(m.identity) == self.snapshot_identity() {
                    return Err(invalid("active snapshot protected"));
                }
                Ok(())
            });
        if let Err(e) = validated {
            return Mutation::Failed(e.to_string());
        }
        autoreleasepool(|_| {
            let Some(url) = (if target.kind == Kind::Dir {
                NSURL::from_directory_path(&target.path)
            } else {
                NSURL::from_file_path(&target.path)
            }) else {
                return Mutation::Failed("Foundation URL conversion failed".into());
            };
            let manager = NSFileManager::defaultManager();
            let mut result: Option<Retained<NSURL>> = None;
            // SAFETY: SDK NSFileManager.h declares BOOL trashItemAtURL:(NSURL *)
            // resultingItemURL:(NSURL * _Nullable * _Nullable) error:(NSError **).
            // objc2's retained out-parameter/error pattern matches these exact types.
            let moved: Result<(), Retained<NSError>> = unsafe {
                msg_send![&*manager, trashItemAtURL: &*url, resultingItemURL: Some(&mut result), error: _]
            };
            match moved {
                Err(e) => Mutation::Indeterminate(format!(
                    "Foundation Trash error (no delete fallback): {e:?}"
                )),
                Ok(()) => match result
                    .filter(|url| url.isFileURL())
                    .and_then(|url| url.to_file_path())
                {
                    Some(destination) => Mutation::Trashed { destination },
                    None => Mutation::Indeterminate(
                        "Trash succeeded without a usable destination URL".into(),
                    ),
                },
            }
        })
    }
    fn remove(&mut self, target: &Target, pin: &Self::Pin) -> Mutation {
        if let Err(e) = stat_fd(&pin._file).and_then(|m| check(&m, target)) {
            return Mutation::Failed(e.to_string());
        }
        let mut removed = 0;
        let result = (|| {
            self.preflight(target)?;
            let (parent, name) = parent(&target.path)?;
            check(&stat_at(&parent, &name)?, target)?;
            remove_at(
                &parent,
                &name,
                target.identity,
                target.kind,
                self.identity,
                target.identity.device,
                &mut removed,
            )
        })();
        match result {
            Ok(()) => Mutation::Removed,
            Err(e) if removed == 0 => Mutation::Failed(e.to_string()),
            Err(e) => Mutation::Partial(e.to_string()),
        }
    }
    fn classify_destination(&mut self, path: &Path, root: Identity) -> DestinationScope {
        classify(path, root).unwrap_or(DestinationScope::Unknown)
    }
}
fn remove_at(
    parent: &File,
    name: &CString,
    expected: Identity,
    kind: Kind,
    snapshot: Identity,
    device: u64,
    removed: &mut usize,
) -> io::Result<()> {
    let current = stat_at(parent, name)?;
    if current.identity != expected
        || current.kind != kind
        || expected == snapshot
        || expected.device != device
        || current.flags & crate::native::SF_FIRMLINK != 0
    {
        return Err(invalid("removal target changed or is protected/excluded"));
    }
    if kind == Kind::Dir {
        let dir = open_at(parent, name)?;
        if stat_fd(&dir)?.identity != expected {
            return Err(invalid("directory replaced before open"));
        }
        for entry in enumerate(&dir)? {
            if entry.metadata.mount {
                return Err(invalid("refusing mounted child"));
            }
            let name = CString::new(entry.name).map_err(|_| invalid("invalid child name"))?;
            remove_at(
                &dir,
                &name,
                entry.metadata.identity,
                entry.metadata.kind,
                snapshot,
                device,
                removed,
            )?;
        }
    }
    let current = stat_at(parent, name)?;
    if current.identity != expected || current.kind != kind {
        return Err(invalid("entry replaced before unlink"));
    }
    // SAFETY: valid parent/name, directory flag only for checked directory. unlinkat
    // unlinks a symlink itself, never its target. Namespace races remain possible.
    if unsafe {
        libc::unlinkat(
            parent.as_raw_fd(),
            name.as_ptr(),
            if kind == Kind::Dir {
                libc::AT_REMOVEDIR
            } else {
                0
            },
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    *removed += 1;
    Ok(())
}
fn classify(path: &Path, root: Identity) -> io::Result<DestinationScope> {
    let (mut dir, name) = parent(path)?;
    // A missing resulting entry cannot establish scope.
    stat_at(&dir, &name)?;
    let mut names = vec![name.as_bytes().to_vec()];
    let mut spelling = path.parent().unwrap();
    loop {
        let m = stat_fd(&dir)?;
        if m.identity == root {
            names.reverse();
            return Ok(DestinationScope::Inside(names.join(&b'/')));
        }
        let up = open_at(&dir, &CString::new("..").unwrap())?;
        let up_id = stat_fd(&up)?.identity;
        if up_id == m.identity {
            return Ok(DestinationScope::Outside);
        }
        // Verify each recovered component against descriptor ancestry. An alias
        // whose spelling cannot be represented this way is unknown, not guessed.
        let component = spelling
            .file_name()
            .ok_or_else(|| invalid("unrepresentable destination ancestry"))?;
        if stat_at(&up, &c_name(component)?)?.identity != m.identity {
            return Err(invalid("destination ancestry changed"));
        }
        names.push(component.as_bytes().to_vec());
        spelling = spelling
            .parent()
            .ok_or_else(|| invalid("unknown destination ancestry"))?;
        dir = up;
    }
}
