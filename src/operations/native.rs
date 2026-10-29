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

#[derive(Clone, Copy, Debug, Default)]
pub(super) struct EnumerationWork {
    pub records: usize,
    pub child_stat_calls: usize,
}

pub struct NativeFileSystem {
    snapshot: File,
    /// The path the snapshot was opened with: its own location, unlike an extra hard link.
    snapshot_path: PathBuf,
    identity: Identity,
    root: Identity,
    /// `/usr/share/firmlinks`, read once: (system-volume path, Data-volume path).
    firmlinks: Option<Vec<(PathBuf, PathBuf)>>,
    #[cfg(test)]
    pub(super) enumeration_work: EnumerationWork,
    /// Directory records listed by the removal walk.
    #[cfg(test)]
    pub(super) removal_records: usize,
    #[cfg(test)]
    pub(super) metadata_requests: usize,
    #[cfg(test)]
    pub(super) enumeration_elapsed: std::time::Duration,
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
                snapshot_path: path.to_path_buf(),
                identity,
                root,
                firmlinks: None,
                #[cfg(test)]
                enumeration_work: EnumerationWork::default(),
                #[cfg(test)]
                removal_records: 0,
                #[cfg(test)]
                metadata_requests: 0,
                #[cfg(test)]
                enumeration_elapsed: std::time::Duration::ZERO,
            },
        ))
    }
    fn firmlinks(&mut self) -> io::Result<&[(PathBuf, PathBuf)]> {
        if self.firmlinks.is_none() {
            let list = match std::fs::read("/usr/share/firmlinks") {
                Ok(bytes) => parse_firmlinks(&bytes),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
                Err(e) => return Err(e),
            };
            self.firmlinks = Some(list);
        }
        Ok(self.firmlinks.as_deref().unwrap_or_default())
    }
    /// T4: the active snapshot's own path is not below the target. That is the path it was
    /// opened with while it still names the snapshot, else the descriptor's path. With
    /// extra hard links the descriptor may name any of them, the most recently looked up.
    fn snapshot_within(&self, target: &Target) -> io::Result<bool> {
        let m = stat_fd(&self.snapshot)?;
        if m.identity.device != target.identity.device || m.links == 0 {
            return Ok(false);
        }
        let opened = parent(&self.snapshot_path).and_then(|(dir, name)| stat_at(&dir, &name));
        if opened.is_ok_and(|m| m.identity == self.identity && m.kind == Kind::File) {
            return directory_above(&self.snapshot_path, target.identity);
        }
        let mut path = vec![0u8; libc::PATH_MAX as usize];
        // SAFETY: F_GETPATH writes at most MAXPATHLEN bytes, NUL-terminated, to the buffer.
        if unsafe {
            libc::fcntl(
                self.snapshot.as_raw_fd(),
                libc::F_GETPATH,
                path.as_mut_ptr(),
            )
        } == -1
        {
            return Err(io::Error::last_os_error());
        }
        let end = path
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| invalid("unterminated snapshot path"))?;
        path.truncate(end);
        directory_above(Path::new(OsStr::from_bytes(&path)), target.identity)
    }
}
/// `/usr/share/firmlinks` lines are "/system-path<TAB>data-relative-path".
fn parse_firmlinks(bytes: &[u8]) -> Vec<(PathBuf, PathBuf)> {
    bytes
        .split(|&b| b == b'\n')
        .filter_map(|line| {
            let tab = line.iter().position(|&b| b == b'\t')?;
            let (system, data) = (&line[..tab], &line[tab + 1..]);
            let data = data.strip_prefix(b"/").unwrap_or(data);
            (system.starts_with(b"/") && !data.is_empty()).then(|| {
                (
                    PathBuf::from(OsStr::from_bytes(system)),
                    Path::new(DATA_VOLUME).join(OsStr::from_bytes(data)),
                )
            })
        })
        .collect()
}
const DATA_VOLUME: &str = "/System/Volumes/Data";
/// The path and its other spelling through the Data-volume firmlinks.
fn spellings(path: &Path) -> [PathBuf; 2] {
    match path.strip_prefix(DATA_VOLUME) {
        Ok(rest) => [path.to_path_buf(), Path::new("/").join(rest)],
        Err(_) => [
            path.to_path_buf(),
            Path::new(DATA_VOLUME).join(path.strip_prefix("/").unwrap_or(path)),
        ],
    }
}
/// Whether `path` is `directory` or below it, by components, ignoring ASCII case: a case
/// variant on a case-insensitive volume still becomes a candidate.
fn at_or_below(path: &Path, directory: &Path) -> bool {
    let mut components = path.components();
    directory.components().all(|d| {
        components.next().is_some_and(|c| {
            c.as_os_str()
                .as_bytes()
                .eq_ignore_ascii_case(d.as_os_str().as_bytes())
        })
    })
}
/// Whether a directory with this identity is among the parents of `path`, following `..`
/// from the parent of `path`; `path` itself is never opened.
fn directory_above(path: &Path, directory: Identity) -> io::Result<bool> {
    let mut dir = crate::open_directory(
        path.parent()
            .ok_or_else(|| invalid("path needs a parent"))?,
    )?;
    let up = CString::new("..").unwrap();
    loop {
        let m = stat_fd(&dir)?;
        if m.identity == directory {
            return Ok(true);
        }
        let parent = open_at(&dir, &up)?;
        if stat_fd(&parent)?.identity == m.identity {
            return Ok(false);
        }
        dir = parent;
    }
}
/// T5/T6: the first endpoint at or below the target. Each endpoint is a spelling and the
/// paths whose parents confirm it. Text selects the candidates first, in both target
/// spellings, so no other endpoint is ever opened (a dead network mount would hang). The
/// parent identities of a candidate then confirm it; one that cannot be checked counts.
fn endpoint_within(target: &Target, endpoints: &[(PathBuf, Vec<PathBuf>)]) -> Option<PathBuf> {
    let spellings = spellings(&target.path);
    let mut candidates: Vec<_> = endpoints
        .iter()
        .filter(|(text, _)| spellings.iter().any(|t| at_or_below(text, t)))
        .collect();
    candidates.sort_by_key(|(text, _)| text.components().count());
    candidates.into_iter().find_map(|(text, confirm)| {
        let itself = spellings
            .iter()
            .any(|t| at_or_below(text, t) && t.components().count() == text.components().count());
        let inside = itself
            || confirm
                .iter()
                .any(|path| directory_above(path, target.identity).unwrap_or(true));
        inside.then(|| text.clone())
    })
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
fn enumerate(dir: &File, work: &mut EnumerationWork) -> io::Result<Vec<DirectoryEntry>> {
    let mut entries = Vec::new();
    let mut error = None;
    crate::native::enumerate(dir, |record| {
        let result = (|| {
            let e = record.result?;
            work.records += 1;
            let m = scan_metadata(dir, &record.name, e, work)?;
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
fn scan_metadata(
    dir: &File,
    name: &[u8],
    e: crate::Entry,
    work: &mut EnumerationWork,
) -> io::Result<ScanMetadata> {
    // Symlink bulk fields are deliberately undefined in the shared parser. Obtain
    // their identity without following them so recursive removal can still check
    // the exact entry. A missing directory allocation is the other allowed fallback.
    let allocation = if let Some(allocation) = e.allocation {
        allocation
    } else {
        if !matches!(e.kind, Kind::Dir | Kind::Symlink) {
            return Err(invalid("missing bulk file allocation"));
        }
        work.child_stat_calls += 1;
        let m = stat_at(
            dir,
            &CString::new(name).map_err(|_| invalid("invalid child name"))?,
        )?;
        if e.kind != m.kind
            || (e.kind != Kind::Symlink
                && (e.dev != m.identity.device || e.ino != m.identity.inode))
        {
            return Err(invalid("child changed during enumeration fallback"));
        }
        if e.kind == Kind::Symlink {
            return Ok(ScanMetadata::from(&m));
        }
        m.allocated_bytes
    };
    Ok(ScanMetadata {
        identity: Identity {
            device: e.dev,
            inode: e.ino,
        },
        kind: e.kind,
        allocated_bytes: allocation,
        links: e.links,
        flags: e.flags,
        mount: e.mount != 0,
    })
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
        #[cfg(test)]
        {
            self.metadata_requests += 1;
        }
        if path == Path::new("/") {
            return stat_fd(&crate::open_directory(path)?);
        }
        let (dir, name) = parent(path)?;
        stat_at(&dir, &name)
    }
    fn read_directory(&mut self, target: &Target) -> io::Result<Vec<DirectoryEntry>> {
        #[cfg(test)]
        let started = std::time::Instant::now();
        let dir = crate::open_directory(&target.path)?;
        check(&stat_fd(&dir)?, target)?;
        let mut work = EnumerationWork::default();
        let result = enumerate(&dir, &mut work);
        #[cfg(test)]
        {
            self.enumeration_elapsed += started.elapsed();
            self.enumeration_work.records += work.records;
            self.enumeration_work.child_stat_calls += work.child_stat_calls;
        }
        result
    }
    fn refuse_protected_within(&mut self, target: &Target) -> io::Result<()> {
        if target.kind != Kind::Dir {
            return Ok(());
        }
        if self.snapshot_within(target)? {
            return Err(invalid("the active snapshot is inside the target"));
        }
        let mounts: Vec<_> = crate::native::mount_paths()?
            .into_iter()
            .map(|mount| (mount.clone(), vec![mount]))
            .collect();
        if let Some(mount) = endpoint_within(target, &mounts) {
            return Err(invalid(&format!(
                "the mounted volume at {} is the target or inside it",
                mount.display()
            )));
        }
        let firmlinks: Vec<_> = self
            .firmlinks()?
            .iter()
            .flat_map(|(system, data)| {
                let confirm = vec![system.clone(), data.clone()];
                [(system.clone(), confirm.clone()), (data.clone(), confirm)]
            })
            .collect();
        if let Some(firmlink) = endpoint_within(target, &firmlinks) {
            return Err(invalid(&format!(
                "the firmlink {} is the target or inside it",
                firmlink.display()
            )));
        }
        Ok(())
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
            .refuse_protected_within(target)
            .and_then(|()| trash_on_same_volume(target))
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
    fn remove(
        &mut self,
        target: &Target,
        pin: &Self::Pin,
        control: Option<&ScanControl>,
    ) -> Mutation {
        if let Err(e) = stat_fd(&pin._file).and_then(|m| check(&m, target)) {
            return Mutation::Failed(e.to_string());
        }
        let (parent, name) = match parent(&target.path).and_then(|(parent, name)| {
            check(&stat_at(&parent, &name)?, target).map(|()| (parent, name))
        }) {
            Ok(found) => found,
            Err(e) => return Mutation::Failed(e.to_string()),
        };
        let mut walk = NativeRemoval {
            protected: [self.root, self.identity],
            device: target.identity.device,
            path: target.path.clone(),
            walk: RemovalWalk::new(control),
            records: 0,
        };
        let result = walk.remove(&parent, &name, target.identity, target.kind);
        #[cfg(test)]
        {
            self.removal_records += walk.records;
        }
        walk.walk.outcome(result)
    }
    fn classify_destination(&mut self, path: &Path, root: Identity) -> DestinationScope {
        classify(path, root).unwrap_or(DestinationScope::Unknown)
    }
}
/// T7: Foundation's Trash for this item is on the item's own volume, so the move is a
/// rename, never a copy. A volume without a usable Trash is refused; there is no fallback.
fn trash_on_same_volume(target: &Target) -> io::Result<()> {
    autoreleasepool(|_| {
        let url = if target.kind == Kind::Dir {
            NSURL::from_directory_path(&target.path)
        } else {
            NSURL::from_file_path(&target.path)
        }
        .ok_or_else(|| invalid("Foundation URL conversion failed"))?;
        let manager = NSFileManager::defaultManager();
        // SAFETY: SDK NSFileManager.h declares (NSURL *)URLForDirectory:(NSSearchPathDirectory)
        // inDomain:(NSSearchPathDomainMask) appropriateForURL:(NSURL *) create:(BOOL)
        // error:(NSError **); both enums are NSUInteger. NSTrashDirectory is 102 and
        // NSUserDomainMask is 1. create:NO creates nothing.
        let trash: Result<Retained<NSURL>, Retained<NSError>> = unsafe {
            msg_send![&*manager, URLForDirectory: 102usize, inDomain: 1usize, appropriateForURL: &*url, create: false, error: _]
        };
        let trash = trash
            .ok()
            .and_then(|url| url.to_file_path())
            .ok_or_else(|| invalid("this volume has no usable Trash; nothing was moved"))?;
        let m = stat_fd(&crate::open_directory(&trash)?)?;
        if m.identity.device != target.identity.device {
            return Err(invalid(
                "the Trash for this item is on another volume; nothing was moved",
            ));
        }
        Ok(())
    })
}
/// The native removal walk. Skipped: permission denied (EACCES), not permitted (EPERM,
/// such as a locked file), an entry changed since it was listed, a protected entry and a
/// folder that still holds a skipped entry. Any other error ends the walk: EIO, ENOTDIR,
/// ELOOP, EMFILE, a failed listing or a lost device.
struct NativeRemoval<'a> {
    protected: [Identity; 2],
    device: u64,
    /// The current entry, for skip reasons only.
    path: PathBuf,
    walk: RemovalWalk<'a>,
    records: usize,
}
impl NativeRemoval<'_> {
    /// Ok(false): the entry stays, because it or an entry below it was skipped.
    fn remove(
        &mut self,
        parent: &File,
        name: &CString,
        expected: Identity,
        kind: Kind,
    ) -> io::Result<bool> {
        self.walk.check_stop()?;
        if self.protected.contains(&expected) || expected.device != self.device {
            return Ok(self.skip("protected: scan root, active snapshot or another volume"));
        }
        if kind == Kind::Dir {
            // A directory gets one stat before it is opened, so a swap for a symlink is a
            // skipped change rather than an O_NOFOLLOW error that would end the walk.
            match stat_at(parent, name) {
                Ok(m) if m.identity != expected || m.kind != kind => {
                    return Ok(self.skip("changed since it was listed"));
                }
                Ok(m) if m.flags & crate::native::SF_FIRMLINK != 0 => {
                    return Ok(self.skip("protected: firmlink"));
                }
                Ok(_) => {}
                Err(e) => return self.failed(e),
            }
            let dir = match open_at(parent, name) {
                Ok(dir) => dir,
                Err(e) => return self.failed(e),
            };
            if stat_fd(&dir)?.identity != expected {
                return Ok(self.skip("changed since it was listed"));
            }
            let mut work = EnumerationWork::default();
            let entries = enumerate(&dir, &mut work)?;
            self.records += work.records;
            let mut kept = false;
            for entry in entries {
                self.path.push(OsStr::from_bytes(&entry.name));
                let gone = if entry.metadata.mount {
                    self.skip("protected: mounted volume")
                } else {
                    let name =
                        CString::new(entry.name).map_err(|_| invalid("invalid child name"))?;
                    self.remove(&dir, &name, entry.metadata.identity, entry.metadata.kind)?
                };
                self.path.pop();
                kept |= !gone;
            }
            if kept {
                return Ok(false);
            }
        }
        // The only stat of a file: the listing gave its identity, this confirms it.
        match stat_at(parent, name) {
            Ok(m) if m.identity != expected || m.kind != kind => {
                return Ok(self.skip("changed since it was listed"));
            }
            Ok(m) if m.flags & crate::native::SF_FIRMLINK != 0 => {
                return Ok(self.skip("protected: firmlink"));
            }
            Ok(_) => {}
            Err(e) => return self.failed(e),
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
            return self.failed(io::Error::last_os_error());
        }
        self.walk.removed();
        Ok(true)
    }
    fn skip(&mut self, reason: &str) -> bool {
        self.walk.skip(&self.path, reason)
    }
    /// An entry that vanished is gone, not skipped; a skip class continues the walk.
    fn failed(&mut self, e: io::Error) -> io::Result<bool> {
        match e.raw_os_error() {
            Some(libc::ENOENT) => Ok(true),
            Some(libc::EACCES) => Ok(self.skip("permission denied")),
            Some(libc::EPERM) => Ok(self.skip("not permitted, for example locked")),
            Some(libc::ENOTEMPTY) => Ok(self.skip("new contents appeared during deletion")),
            _ => Err(e),
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::operations::tests::Fixture;

    #[test]
    fn firmlink_list_parses_system_and_data_volume_paths() {
        let list = parse_firmlinks(b"/Users\tUsers\n/usr/local\tusr/local\n\nbroken\n");
        assert_eq!(
            list,
            [
                ("/Users".into(), "/System/Volumes/Data/Users".into()),
                ("/usr/local".into(), "/System/Volumes/Data/usr/local".into()),
            ]
        );
        assert_eq!(
            spellings(Path::new("/System/Volumes/Data/usr")),
            [PathBuf::from("/System/Volumes/Data/usr"), "/usr".into()]
        );
        assert_eq!(
            spellings(Path::new("/usr")),
            [PathBuf::from("/usr"), "/System/Volumes/Data/usr".into()]
        );
    }
    #[test]
    fn endpoints_inside_the_target_are_found_by_text_then_parent_identity() {
        let fixture = Fixture::new();
        let target_path = fixture.0.join("target");
        std::fs::create_dir_all(target_path.join("deep/mnt")).unwrap();
        std::fs::create_dir_all(fixture.0.join("target-sibling/mnt")).unwrap();
        let m = stat_fd(&crate::open_directory(&target_path).unwrap()).unwrap();
        let target = Target {
            path: target_path.clone(),
            identity: m.identity,
            kind: Kind::Dir,
        };
        let endpoint = |path: PathBuf| vec![(path.clone(), vec![path])];
        let inside = target_path.join("deep/mnt");
        assert_eq!(
            endpoint_within(&target, &endpoint(inside.clone())),
            Some(inside)
        );
        // The target itself is a mount point.
        assert!(endpoint_within(&target, &endpoint(target_path.clone())).is_some());
        // The other spelling through the Data volume, when this host has it.
        let data =
            Path::new(DATA_VOLUME).join(target_path.join("deep/mnt").strip_prefix("/").unwrap());
        if crate::open_directory(&data).is_ok() {
            assert_eq!(
                endpoint_within(&target, &endpoint(data.clone())),
                Some(data)
            );
        }
        // A case variant on this case-insensitive volume is confirmed by identity.
        let variant = PathBuf::from(
            target_path
                .join("DEEP/mnt")
                .to_string_lossy()
                .replacen("/target/", "/TARGET/", 1),
        );
        if crate::open_directory(&variant).is_ok() {
            assert_eq!(
                endpoint_within(&target, &endpoint(variant.clone())),
                Some(variant)
            );
        }
        // An endpoint whose parent cannot be opened counts as inside.
        let unknown = target_path.join("missing/mnt");
        assert_eq!(
            endpoint_within(&target, &endpoint(unknown.clone())),
            Some(unknown)
        );
        // Text excludes other paths without opening them.
        for outside in [
            fixture.0.join("target-sibling/mnt"),
            fixture.0.clone(),
            PathBuf::from("/Volumes/never-opened/mnt"),
        ] {
            assert_eq!(endpoint_within(&target, &endpoint(outside)), None);
        }
        // A text candidate whose parents are not the target is dropped by identity.
        let mut wrong = target.clone();
        wrong.identity.inode += 1_000_000;
        assert_eq!(
            endpoint_within(&wrong, &endpoint(target_path.join("deep/mnt"))),
            None
        );
    }

    #[test]
    fn bulk_fallback_checks_directory_identity_and_preserves_symlink_identity() {
        let fixture = Fixture::new();
        std::fs::create_dir(fixture.0.join("child")).unwrap();
        let dir = crate::open_directory(&fixture.0).unwrap();
        let m = stat_at(&dir, &CString::new("child").unwrap()).unwrap();
        let directory = |inode| crate::Entry {
            kind: Kind::Dir,
            dev: m.identity.device,
            ino: inode,
            flags: 16,
            links: 1,
            allocation: None,
            mount: 1,
        };
        let mut work = EnumerationWork::default();
        let scan = scan_metadata(&dir, b"child", directory(m.identity.inode), &mut work).unwrap();
        assert_eq!(scan.identity, m.identity);
        assert_eq!(scan.allocated_bytes, m.allocated_bytes);
        assert_eq!(scan.links, 1);
        assert_eq!(scan.flags, 16);
        assert!(scan.mount);
        assert_eq!(work.child_stat_calls, 1);
        assert!(scan_metadata(&dir, b"child", directory(m.identity.inode + 1), &mut work).is_err());
        assert_eq!(work.child_stat_calls, 2);
        std::fs::write(fixture.0.join("outside"), b"owned target").unwrap();
        std::os::unix::fs::symlink(fixture.0.join("outside"), fixture.0.join("link")).unwrap();
        let scan = scan_metadata(&dir, b"link", crate::Entry::symlink(), &mut work).unwrap();
        assert_eq!(scan.kind, Kind::Symlink);
        assert_eq!(
            scan.identity,
            stat_at(&dir, &CString::new("link").unwrap())
                .unwrap()
                .identity
        );
        assert_ne!(
            scan.identity,
            stat_at(&dir, &CString::new("outside").unwrap())
                .unwrap()
                .identity
        );
        assert_eq!(work.child_stat_calls, 3);
        // A symlink swapped for a regular file must not acquire symlink treatment.
        assert!(scan_metadata(&dir, b"outside", crate::Entry::symlink(), &mut work).is_err());
    }
}
