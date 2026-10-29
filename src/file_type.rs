//! File-tile type colors: a fixed extension table and the folder rule. Saved names only: no
//! allocation, no path building, no content or filesystem metadata.
use crate::explorer::Explorer;
use std::{os::unix::ffi::OsStrExt, path::Component};

/// Kinds of the design prototype. Colors are its OKLCH L=.62 C=.11 hues, converted once to
/// clipped 8-bit sRGB; documents use C=.02 H=260, the same muted gray as unknown files.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FileType {
    Image,
    Video,
    Audio,
    Archive,
    App,
    Code,
    Cache,
    Data,
    Document,
}
impl FileType {
    pub(crate) const fn color(self) -> [u8; 3] {
        match self {
            Self::Image => [81, 153, 98],
            Self::Video => [79, 138, 198],
            Self::Audio => [171, 109, 166],
            Self::Archive => [173, 124, 47],
            Self::App => [133, 122, 196],
            Self::Code => [0, 153, 160],
            Self::Cache => [190, 110, 82],
            Self::Data => [138, 140, 52],
            Self::Document => UNKNOWN_COLOR,
        }
    }
}
/// Files without a known extension outside a context folder.
const UNKNOWN_COLOR: [u8; 3] = [127, 135, 147];

/// Saved basename bytes inspected for an extension. The last `.` must lie inside this tail, so
/// an extension has at most 11 bytes (`swiftmodule`, `sparseimage`, `sqlite-wal`).
const NAME_TAIL: usize = 12;

use FileType::{App, Archive, Audio, Cache, Code, Data, Document, Image, Video};
/// Lowercase ASCII extensions in byte order. Numeric extensions (`.0`, `.1`, `.259`) are not
/// listed. Ambiguous ones follow the common use in a home folder: `ts` and `mts` are
/// TypeScript, `raw` is a disk image (archive), `key` is Keynote. `db*` are caches and
/// `sqlite*` data, as in the prototype; `log` is a document.
const EXTENSIONS: &[(&[u8], FileType)] = &[
    (b"3gp", Video),
    (b"7z", Archive),
    (b"a", Code),
    (b"aac", Audio),
    (b"aar", Archive),
    (b"ai", Image),
    (b"aif", Audio),
    (b"aiff", Audio),
    (b"alac", Audio),
    (b"amr", Audio),
    (b"ape", Audio),
    (b"apk", App),
    (b"app", App),
    (b"appimage", App),
    (b"appx", App),
    (b"arrow", Data),
    (b"arw", Image),
    (b"asar", Archive),
    (b"asm", Code),
    (b"avi", Video),
    (b"avif", Image),
    (b"bash", Code),
    (b"bin", Data),
    (b"bmp", Image),
    (b"bz2", Archive),
    (b"c", Code),
    (b"cab", Archive),
    (b"cache", Cache),
    (b"caf", Audio),
    (b"car", Data),
    (b"cc", Code),
    (b"cjs", Code),
    (b"ckpt", Data),
    (b"class", Code),
    (b"cpio", Archive),
    (b"cpp", Code),
    (b"cr2", Image),
    (b"cr3", Image),
    (b"crate", Archive),
    (b"cs", Code),
    (b"css", Code),
    (b"csv", Data),
    (b"cts", Code),
    (b"d", Code),
    (b"dat", Data),
    (b"data", Data),
    (b"db", Cache),
    (b"db-journal", Cache),
    (b"db-shm", Cache),
    (b"db-wal", Cache),
    (b"deb", Archive),
    (b"dll", Code),
    (b"dmg", Archive),
    (b"dng", Image),
    (b"doc", Document),
    (b"docx", Document),
    (b"dwg", Document),
    (b"dxf", Document),
    (b"dylib", Code),
    (b"dyn_hi", Code),
    (b"egg", Archive),
    (b"eml", Document),
    (b"emlx", Document),
    (b"eps", Image),
    (b"epub", Document),
    (b"exe", App),
    (b"exr", Image),
    (b"feather", Data),
    (b"flac", Audio),
    (b"flv", Video),
    (b"gem", Archive),
    (b"gguf", Data),
    (b"gif", Image),
    (b"go", Code),
    (b"gz", Archive),
    (b"h", Code),
    (b"h5", Data),
    (b"hdr", Image),
    (b"heic", Image),
    (b"heif", Image),
    (b"hi", Code),
    (b"hpp", Code),
    (b"htm", Code),
    (b"html", Code),
    (b"icns", Image),
    (b"ico", Image),
    (b"img", Archive),
    (b"index", Data),
    (b"ini", Data),
    (b"ipa", App),
    (b"ipsw", Archive),
    (b"iso", Archive),
    (b"ithmb", Image),
    (b"jar", Archive),
    (b"java", Code),
    (b"joblib", Data),
    (b"jpeg", Image),
    (b"jpg", Image),
    (b"js", Code),
    (b"json", Data),
    (b"json3", Data),
    (b"jsonl", Data),
    (b"jsx", Code),
    (b"jxl", Image),
    (b"key", Document),
    (b"ldb", Data),
    (b"lib", Code),
    (b"lock", Data),
    (b"log", Document),
    (b"lz4", Archive),
    (b"lzma", Archive),
    (b"m", Code),
    (b"m2ts", Video),
    (b"m4a", Audio),
    (b"m4b", Audio),
    (b"m4p", Audio),
    (b"m4v", Video),
    (b"map", Code),
    (b"markdown", Document),
    (b"md", Document),
    (b"metal", Code),
    (b"metallib", Code),
    (b"mid", Audio),
    (b"midi", Audio),
    (b"mjs", Code),
    (b"mka", Audio),
    (b"mkv", Video),
    (b"mm", Code),
    (b"mobi", Document),
    (b"mov", Video),
    (b"mp3", Audio),
    (b"mp4", Video),
    (b"mpeg", Video),
    (b"mpg", Video),
    (b"mpkg", App),
    (b"msi", App),
    (b"msix", App),
    (b"mts", Code),
    (b"mxf", Video),
    (b"ndjson", Data),
    (b"nef", Image),
    (b"node", Code),
    (b"npy", Data),
    (b"npz", Data),
    (b"numbers", Document),
    (b"nupkg", Archive),
    (b"o", Code),
    (b"odp", Document),
    (b"ods", Document),
    (b"odt", Document),
    (b"oga", Audio),
    (b"ogg", Audio),
    (b"ogv", Video),
    (b"onnx", Data),
    (b"opus", Audio),
    (b"p_hi", Code),
    (b"pack", Archive),
    (b"pages", Document),
    (b"parquet", Data),
    (b"pb", Data),
    (b"pch", Code),
    (b"pdb", Code),
    (b"pdf", Document),
    (b"php", Code),
    (b"pickle", Data),
    (b"pkg", App),
    (b"pkl", Data),
    (b"plist", Data),
    (b"png", Image),
    (b"ppt", Document),
    (b"pptx", Document),
    (b"psd", Image),
    (b"pt", Data),
    (b"pth", Data),
    (b"py", Code),
    (b"pyc", Code),
    (b"pyd", Code),
    (b"pyi", Code),
    (b"pyx", Code),
    (b"qcow2", Archive),
    (b"r", Code),
    (b"rar", Archive),
    (b"raw", Archive),
    (b"rb", Code),
    (b"rlib", Code),
    (b"rmeta", Code),
    (b"rpm", Archive),
    (b"rs", Code),
    (b"rtf", Document),
    (b"s", Code),
    (b"safetensors", Data),
    (b"scss", Code),
    (b"sh", Code),
    (b"sketch", Document),
    (b"skp", Document),
    (b"so", Code),
    (b"sparseimage", Archive),
    (b"sql", Data),
    (b"sqlite", Data),
    (b"sqlite-shm", Data),
    (b"sqlite-wal", Data),
    (b"sqlite3", Data),
    (b"svg", Image),
    (b"swift", Code),
    (b"swiftmodule", Code),
    (b"tar", Archive),
    (b"tbz2", Archive),
    (b"tex", Document),
    (b"tflite", Data),
    (b"tgz", Archive),
    (b"tif", Image),
    (b"tiff", Image),
    (b"tmp", Cache),
    (b"toml", Data),
    (b"ts", Code),
    (b"tsv", Data),
    (b"tsx", Code),
    (b"txt", Document),
    (b"txz", Archive),
    (b"vdi", Archive),
    (b"vhdx", Archive),
    (b"vmdk", Archive),
    (b"vob", Video),
    (b"wasm", Code),
    (b"wav", Audio),
    (b"webm", Video),
    (b"webp", Image),
    (b"whl", Archive),
    (b"wma", Audio),
    (b"wmv", Video),
    (b"xar", Archive),
    (b"xip", Archive),
    (b"xls", Document),
    (b"xlsx", Document),
    (b"xml", Data),
    (b"xz", Archive),
    (b"yaml", Data),
    (b"yml", Data),
    (b"zip", Archive),
    (b"zst", Archive),
];

/// An extension of 1 to 16 bytes as one nonzero integer, lowercase, first byte highest.
const fn extension_key(extension: &[u8]) -> u128 {
    let mut key = 0;
    let mut at = 0;
    while at < extension.len() {
        key = key << 8 | extension[at].to_ascii_lowercase() as u128;
        at += 1;
    }
    key << (8 * (16 - extension.len()))
}
/// Slot of a key in the open-addressing table: a multiplicative hash of both halves.
const fn slot(key: u128) -> usize {
    let mixed = (key >> 64) as u64 ^ (key as u64).rotate_left(29);
    (mixed.wrapping_mul(0x9e37_79b9_7f4a_7c15) >> (64 - SLOT_BITS)) as usize
}
const SLOT_BITS: u32 = 9;
/// The extension table as a hash table, built at compile time with linear probing. Key 0
/// marks an empty slot; fewer than half of the 512 slots are used, so a lookup usually reads
/// one slot.
const SLOTS: [(u128, FileType); 1 << SLOT_BITS] = {
    let mut slots = [(0, Image); 1 << SLOT_BITS];
    let mut at = 0;
    while at < EXTENSIONS.len() {
        let key = extension_key(EXTENSIONS[at].0);
        let mut probe = slot(key);
        while slots[probe].0 != 0 {
            assert!(slots[probe].0 != key, "duplicate extension");
            probe = (probe + 1) % slots.len();
        }
        slots[probe] = (key, EXTENSIONS[at].1);
        at += 1;
    }
    slots
};

/// Kind of a known extension: the bytes after the last `.` in the name's tail, compared ASCII
/// case-insensitively. Other bytes, including non-UTF-8 bytes, never match.
pub(crate) fn file_type(name: &[u8]) -> Option<FileType> {
    let tail = &name[name.len().saturating_sub(NAME_TAIL)..];
    let extension = &tail[tail.iter().rposition(|&b| b == b'.')? + 1..];
    if extension.is_empty() {
        return None;
    }
    let key = extension_key(extension);
    let mut probe = slot(key);
    loop {
        match SLOTS[probe] {
            (0, _) => return None,
            (known, kind) if known == key => return Some(kind),
            _ => probe = (probe + 1) % SLOTS.len(),
        }
    }
}

/// The folder rule for one directory, computed once from its own name and its parent's
/// context. A file without a known extension (none, unknown or numeric) inside a context folder
/// takes the context color; a known extension keeps its own color. The nearest context wins.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct FolderContext {
    fallback: Option<FileType>,
    /// What this directory's own name means for its child directories.
    marker: Marker,
    /// This directory or an ancestor is named `huggingface`.
    huggingface: bool,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Marker {
    #[default]
    None,
    /// A Git directory: `.git` or a bare repository `<name>.git`. A child `objects` holds Git
    /// objects; a child `modules` holds submodule Git directories.
    GitDirectory,
    /// `modules` inside a Git directory. Its children start submodule names.
    GitModules,
    /// Any directory below `modules` inside a Git directory. Git names a submodule after its
    /// path, so a name may span several directories (`modules/vendor/lib`), and only the
    /// submodule's configuration knows where it ends. Each such directory may be a submodule's
    /// Git directory, so a child `objects` holds Git objects. Known false positive: an
    /// `objects` that is a path segment of a submodule name (`modules/lib/objects/x`) or a
    /// submodule's ref folder (`modules/lib/refs/heads/objects`) is archive too, and so are
    /// the files below it without a known extension (`x/HEAD`, `x/config`).
    Submodule,
    /// `lfs`: a child `objects` holds Git LFS objects.
    Lfs,
    /// `pnpm`: a child `store` is the pnpm store.
    Pnpm,
    /// `models--*` or `datasets--*`: a child `blobs` is the Hugging Face blob store.
    HubRepository,
}
/// Marker of the directory `name` inside a directory with marker `parent`.
fn marker(name: &[u8], parent: Marker) -> Marker {
    match name {
        _ if parent == Marker::GitModules || parent == Marker::Submodule => Marker::Submodule,
        _ if name.ends_with(b".git") => Marker::GitDirectory,
        b"modules" if parent == Marker::GitDirectory => Marker::GitModules,
        b"lfs" => Marker::Lfs,
        b"pnpm" => Marker::Pnpm,
        _ if name.starts_with(b"models--") || name.starts_with(b"datasets--") => {
            Marker::HubRepository
        }
        _ => Marker::None,
    }
}
/// Marker of the first of `names` (a directory and its ancestors, nearest first), equal to
/// `marker` applied from the top. `submodule` tells whether the directory lies below `modules`
/// inside a Git directory; otherwise only its parent's name matters.
fn marker_at<'a>(mut names: impl Iterator<Item = &'a [u8]>, submodule: bool) -> Marker {
    let Some(name) = names.next() else {
        return Marker::None;
    };
    if submodule {
        return Marker::Submodule;
    }
    let parent = match names.next() {
        Some(parent) if parent.ends_with(b".git") => Marker::GitDirectory,
        _ => Marker::None,
    };
    marker(name, parent)
}
/// Exact, case-sensitive byte matches, so that ordinary folders rarely match.
fn folder_type(name: &[u8], parent: Marker, huggingface_above: bool) -> Option<FileType> {
    match name {
        b"objects"
            if matches!(
                parent,
                Marker::GitDirectory | Marker::Submodule | Marker::Lfs
            ) =>
        {
            Some(Archive)
        }
        b"Caches" | b"Cache" | b".cache" | b"_cacache" | b".pnpm-store" => Some(Cache),
        b"store" if parent == Marker::Pnpm => Some(Cache),
        b"blobs" if huggingface_above || parent == Marker::HubRepository => Some(Cache),
        _ => None,
    }
}
impl FolderContext {
    /// Context of the child directory `name`.
    pub(crate) fn enter(self, name: &[u8]) -> Self {
        Self {
            fallback: folder_type(name, self.marker, self.huggingface).or(self.fallback),
            marker: marker(name, self.marker),
            huggingface: self.huggingface || name == b"huggingface",
        }
    }
    /// Base color of a file named `name` in this folder.
    pub(crate) fn file_color(self, name: &[u8]) -> [u8; 3] {
        file_type(name)
            .or(self.fallback)
            .map_or(UNKNOWN_COLOR, FileType::color)
    }
}
impl Explorer {
    /// Context of directory `id` from the saved root path's components and the saved
    /// ancestors, nearest first: O(depth), no allocation. Equal to `enter` applied from `/`.
    pub(crate) fn folder_context(&self, id: u32) -> FolderContext {
        let names = || {
            std::iter::successors(Some(id), |&at| {
                (at != 0).then(|| self.map.nodes[at as usize].parent)
            })
            .filter(|&at| at != 0)
            .map(|at| self.map.basename(at as usize))
            .chain(
                self.map
                    .root
                    .components()
                    .rev()
                    .filter_map(|part| match part {
                        Component::Normal(name) => Some(name.as_bytes()),
                        _ => None,
                    }),
            )
        };
        let top_huggingface = names()
            .enumerate()
            .filter(|(_, name)| *name == b"huggingface")
            .map(|(distance, _)| distance)
            .last();
        // The directory at distance `d` lies below `modules` inside a Git directory if a
        // `modules` with a `.git` parent is farther than `d`; the farthest one decides.
        let top_git_modules = names()
            .zip(names().skip(1))
            .enumerate()
            .filter(|(_, (name, parent))| *name == b"modules" && parent.ends_with(b".git"))
            .map(|(distance, _)| distance)
            .last();
        let submodule = |distance: usize| top_git_modules.is_some_and(|top| top > distance);
        let mut ancestors = names();
        let mut distance = 0;
        let fallback = loop {
            let Some(name) = ancestors.next() else {
                break None;
            };
            let huggingface_above = top_huggingface.is_some_and(|top| top > distance);
            let parent = marker_at(ancestors.clone(), submodule(distance + 1));
            if let Some(kind) = folder_type(name, parent, huggingface_above) {
                break Some(kind);
            }
            distance += 1;
        };
        FolderContext {
            fallback,
            marker: marker_at(names(), submodule(0)),
            huggingface: top_huggingface.is_some(),
        }
    }
}

#[cfg(test)]
mod tests;
