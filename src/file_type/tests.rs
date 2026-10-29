use super::*;
use crate::{Counters, Entry, Kind, Map};

const GRAY: [u8; 3] = UNKNOWN_COLOR;

/// Context reached by entering `folders` from `/`, the forward rule that layout applies.
fn entered(folders: &[&[u8]]) -> FolderContext {
    folders
        .iter()
        .fold(FolderContext::default(), |context, name| {
            context.enter(name)
        })
}

#[test]
fn extension_table_is_sorted_lowercase_and_fits_the_name_tail() {
    assert!(
        (150..=250).contains(&EXTENSIONS.len()),
        "{}",
        EXTENSIONS.len()
    );
    for pair in EXTENSIONS.windows(2) {
        assert!(pair[0].0 < pair[1].0, "{:?}", pair[0].0);
    }
    // Every listed extension sits in the hash table, at most 4 slots after its own slot.
    let used = SLOTS.iter().filter(|(key, _)| *key != 0).count();
    assert_eq!(used, EXTENSIONS.len());
    for (extension, _) in EXTENSIONS {
        let key = extension_key(extension);
        let distance = (0..SLOTS.len())
            .find(|step| SLOTS[(slot(key) + step) % SLOTS.len()].0 == key)
            .unwrap();
        assert!(distance <= 4, "{}", extension.escape_ascii());
    }
    for (extension, _) in EXTENSIONS {
        assert!(!extension.is_empty() && extension.len() < NAME_TAIL);
        assert!(
            extension
                .iter()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"-_".contains(b))
        );
        assert!(!extension.iter().all(u8::is_ascii_digit), "numeric");
        assert_eq!(
            file_type(&[b"a.", *extension].concat()),
            Some(file_type_of(extension))
        );
    }
}
fn file_type_of(extension: &[u8]) -> FileType {
    EXTENSIONS.iter().find(|(e, _)| *e == extension).unwrap().1
}

#[test]
fn known_extensions_map_to_each_kind_case_insensitively_within_the_name_tail() {
    for (names, kind) in [
        (&[&b"a.png"[..], b"b.HEIC", b"c.psd", b"d.svg"][..], Image),
        (&[b"a.mov", b"b.webm", b"c.M4V"], Video),
        (&[b"a.wav", b"b.opus", b"c.Flac"], Audio),
        (
            &[b"a.zip", b"pack-1f.pack", b"c.whl", b"d.crate", b"e.raw"],
            Archive,
        ),
        (&[b"Install.app", b"b.exe", b"c.pkg"], App),
        (
            &[
                b"a.rs",
                b"b.dylib",
                b"c.so",
                b"libd.a",
                b"e.ts",
                b"f.js.map",
            ],
            Code,
        ),
        (&[b"a.cache", b"b.db", b"c.db-wal"], Cache),
        (
            &[b"a.bin", b"b.jsonl", b"c.json", b"d.CSV", b"e.sqlite-wal"],
            Data,
        ),
        (
            &[b"a.pdf", b"b.md", b"c.txt", b"d.log", b"e.docx"],
            Document,
        ),
    ] {
        for name in names {
            assert_eq!(file_type(name), Some(kind), "{}", name.escape_ascii());
            assert_eq!(FolderContext::default().file_color(name), kind.color());
        }
    }
    // Every colored kind has its own color; documents share the unknown gray.
    let colors = [Image, Video, Audio, Archive, App, Code, Cache, Data].map(FileType::color);
    for (i, color) in colors.iter().enumerate() {
        assert!(!colors[i + 1..].contains(color) && *color != GRAY);
    }
    assert_eq!(Document.color(), GRAY);
    // The tail holds 12 bytes: an extension of up to 11 bytes after its dot.
    assert_eq!(file_type(b"Module.swiftmodule"), Some(Code));
    assert_eq!(file_type(b"disk.sparseimage"), Some(Archive));
    assert_eq!(file_type(b"index.db-journal"), Some(Cache));
    assert_eq!(file_type(b"main.sqlite-journal"), None, "14-byte extension");
    assert_eq!(file_type(b"swiftmodule"), None, "no dot");
    // Numeric, empty, unknown and look-alike extensions stay gray.
    for name in [
        &b"segment.0"[..],
        b"core.1",
        b"chunk.259",
        b"notes.",
        b"",
        b"no-extension",
        b".gitignore",
        b"a.zzz",
        b"notpng",
        b"a.png.part",
    ] {
        assert_eq!(file_type(name), None, "{}", name.escape_ascii());
        assert_eq!(FolderContext::default().file_color(name), GRAY);
    }
    // Raw bytes: non-UTF-8 bytes before the extension are fine and never match themselves.
    assert_eq!(file_type(b"\xff\xfe.PNG"), Some(Image));
    assert_eq!(file_type(b"a.\xffpng"), None);
    assert_eq!(file_type(b"a.p\xc3\xa9"), None);
}

#[test]
fn folder_rule_colors_files_without_a_known_extension_by_context() {
    let archive = Archive.color();
    let cache = Cache.color();
    for (folders, color) in [
        // Git object storage, also loose objects one level down.
        (&[&b"repo"[..], b".git", b"objects"][..], archive),
        (&[b"repo", b".git", b"objects", b"3a"], archive),
        (
            &[b"repo", b".git", b"lfs", b"objects", b"ab", b"cd"],
            archive,
        ),
        (&[b"models", b"lfs", b"objects"], archive),
        // Submodule object storage, nested submodules, bare repositories and their submodules.
        (
            &[b"repo", b".git", b"modules", b"lib", b"objects", b"3a"],
            archive,
        ),
        (
            &[
                b"repo", b".git", b"modules", b"a", b"modules", b"b", b"objects",
            ],
            archive,
        ),
        (
            &[b"repo", b".git", b"modules", b"modules", b"objects"],
            archive,
        ),
        (
            &[b"repo", b".git", b"modules", b"lib", b"lfs", b"objects"],
            archive,
        ),
        (&[b"srv", b"mirror.git", b"objects", b"pack"], archive),
        (
            &[b"srv", b"mirror.git", b"modules", b"lib", b"objects"],
            archive,
        ),
        (&[b"\xff.git", b"objects"], archive),
        // Caches and stores.
        (&[b"Library", b"Caches", b"com.example.viewer"], cache),
        (
            &[
                b"Library",
                b"Application Support",
                b"Viewer",
                b"Cache",
                b"Cache_Data",
            ],
            cache,
        ),
        (&[b".cache", b"tool"], cache),
        (&[b".npm", b"_cacache", b"content-v2", b"sha512"], cache),
        (&[b"work", b".pnpm-store", b"v3"], cache),
        (
            &[b".local", b"share", b"pnpm", b"store", b"v3", b"files"],
            cache,
        ),
        (&[b"Library", b"pnpm", b"store"], cache),
        // Hugging Face blobs: a `huggingface` ancestor or a `models--`/`datasets--` parent.
        (
            &[
                b"hf",
                b"huggingface",
                b"hub",
                b"models--org--name",
                b"blobs",
            ],
            cache,
        ),
        (&[b"huggingface", b"blobs"], cache),
        (&[b"data", b"models--org--name", b"blobs"], cache),
        (&[b"data", b"datasets--org--set", b"blobs", b"x"], cache),
        // The nearest context wins.
        (&[b".cache", b"tool", b".git", b"objects"], archive),
        (&[b"repo", b".git", b"objects", b"Caches"], cache),
        // Non-UTF-8 folder names.
        (&[b"\xff\xfe", b"Caches"], cache),
        (&[b"\xff", b".git", b"objects"], archive),
        // False positives that stay gray.
        (&[b"Projects", b"objects"], GRAY),
        (&[b"Projects", b"objects", b"3a"], GRAY),
        (&[b"repo", b".git"], GRAY),
        (&[b"repo", b".git", b"refs", b"objects"], GRAY),
        (&[b"repo", b".git", b"Objects"], GRAY),
        (&[b"repo", b".Git", b"objects"], GRAY),
        (&[b"modules", b"lib", b"objects"], GRAY),
        (&[b"Projects", b"modules", b"lib", b"objects"], GRAY),
        (&[b"repo", b".git", b"modules"], GRAY),
        (&[b"repo", b".git", b"modules", b"objects"], GRAY),
        (&[b"repo", b".git", b"modules", b"lib"], GRAY),
        (
            &[b"repo", b".git", b"modules", b"lib", b"refs", b"objects"],
            GRAY,
        ),
        (
            &[b"repo", b".git", b"refs", b"modules", b"lib", b"objects"],
            GRAY,
        ),
        (&[b"repo", b".git", b"Modules", b"lib", b"objects"], GRAY),
        (&[b"lfs", b"modules", b"lib", b"objects"], GRAY),
        (&[b"srv", b"mirror.git"], GRAY),
        (&[b"srv", b"mirror.GIT", b"objects"], GRAY),
        (&[b"srv", b"mirror.git.bak", b"objects"], GRAY),
        (&[b"srv", b"mirrorgit", b"objects"], GRAY),
        (&[b"srv", b"mirror.git", b"refs", b"objects"], GRAY),
        (&[b"Library", b"caches"], GRAY),
        (&[b"Library", b"CACHE"], GRAY),
        // Lowercase `cache` stays gray (a user decision): it names many ordinary folders.
        (&[b"cache"], GRAY),
        (&[b"Library", b"cache"], GRAY),
        (&[b"Projects", b"app", b"cache", b"v2"], GRAY),
        (&[b"Projects", b"store"], GRAY),
        (&[b"pnpm-tools", b"store"], GRAY),
        (&[b"pnpm", b"cache", b"store"], GRAY),
        (&[b"backup", b"blobs"], GRAY),
        (&[b"models--org--name", b"snapshots"], GRAY),
        (&[b"models--org--name", b"refs", b"blobs"], GRAY),
        (&[b"huggingface"], GRAY),
        (&[b"blobs", b"huggingface"], GRAY),
    ] {
        let context = entered(folders);
        let path = folders.join(&b'/').escape_ascii().to_string();
        for name in [&b"7c91d0"[..], b"chunk.idx", b"data.1", b"\xff\xfe"] {
            assert_eq!(
                context.file_color(name),
                color,
                "{path}/{}",
                name.escape_ascii()
            );
        }
        // A known extension keeps its own color, gray documents included.
        assert_eq!(context.file_color(b"photo.png"), Image.color(), "{path}");
        assert_eq!(context.file_color(b"pack-1.pack"), archive, "{path}");
        assert_eq!(context.file_color(b"report.pdf"), GRAY, "{path}");
    }
}

fn directory_chain(root: &str, folders: &[&[u8]]) -> (Map, Vec<u32>) {
    let mut map = Map {
        root: root.into(),
        nodes: vec![],
        names: vec![],
        counters: Counters::default(),
        error_samples: vec![],
    };
    let mut ids = vec![];
    let add = |map: &mut Map, parent, name: &[u8]| {
        let entry = Entry {
            kind: Kind::Dir,
            dev: 1,
            ino: map.nodes.len() as u64 + 1,
            flags: 0,
            links: 1,
            allocation: Some(0),
            mount: 0,
        };
        map.add(parent, name, entry).unwrap()
    };
    let mut parent = add(&mut map, 0, b"");
    ids.push(parent);
    for name in folders {
        parent = add(&mut map, parent, name);
        ids.push(parent);
    }
    map.aggregate().unwrap();
    (map, ids)
}

#[test]
fn focus_context_from_saved_ancestors_and_root_path_equals_entering_from_the_root() {
    let chains: [(&str, &[&[u8]]); 11] = [
        (
            "/Users/ana",
            &[b"Projects", b"repo", b".git", b"objects", b"3a"],
        ),
        (
            "/Users/ana",
            &[
                b"hf",
                b"huggingface",
                b"hub",
                b"models--o--n",
                b"blobs",
                b"x",
            ],
        ),
        (
            "/Users/ana",
            &[
                b"blobs",
                b"huggingface",
                b"blobs",
                b"models--o--n",
                b"snapshots",
            ],
        ),
        (
            "/Users/ana/Library/Caches",
            &[b"com.example", b".git", b"objects", b"pack"],
        ),
        ("/Users/ana/repo/.git", &[b"objects", b"ab"]),
        ("/", &[b"pnpm", b"store", b"\xff", b"Caches"]),
        (
            "/Users/ana",
            &[
                b"repo", b".git", b"modules", b"a", b"modules", b"b", b"objects", b"3a",
            ],
        ),
        (
            "/Users/ana",
            &[
                b".git", b"modules", b"modules", b"modules", b"modules", b"objects",
            ],
        ),
        (
            "/Users/ana",
            &[b"modules", b"lib", b"objects", b"x.git", b"objects"],
        ),
        ("/Users/ana/repo/.git/modules/lib", &[b"objects", b"ab"]),
        ("/srv/mirror.git", &[b"modules", b"lib", b"objects"]),
    ];
    for (root, folders) in chains {
        let (map, ids) = directory_chain(root, folders);
        let explorer = Explorer::from_map(map).unwrap();
        let mut forward: Vec<&[u8]> = std::path::Path::new(root)
            .components()
            .filter_map(|part| match part {
                Component::Normal(name) => Some(name.as_bytes()),
                _ => None,
            })
            .collect();
        assert_eq!(explorer.folder_context(0), entered(&forward), "{root}");
        for (depth, &id) in ids.iter().enumerate().skip(1) {
            forward.push(folders[depth - 1]);
            assert_eq!(
                explorer.folder_context(id),
                entered(&forward),
                "{root} {depth}"
            );
        }
    }
    // The saved root path counts: a scan of a Git directory or a cache folder.
    let (map, ids) = directory_chain("/Users/ana/repo/.git", &[b"objects", b"ab"]);
    let explorer = Explorer::from_map(map).unwrap();
    assert_eq!(
        explorer.folder_context(ids[2]).file_color(b"cd12"),
        Archive.color()
    );
    for root in ["/Users/ana/repo/.git/modules/lib", "/srv/mirror.git"] {
        let (map, ids) = directory_chain(root, &[b"objects", b"ab"]);
        let explorer = Explorer::from_map(map).unwrap();
        assert_eq!(
            explorer.folder_context(ids[2]).file_color(b"cd12"),
            Archive.color(),
            "{root}"
        );
    }
    let (map, _) = directory_chain("/Users/ana/Library/Caches", &[]);
    let explorer = Explorer::from_map(map).unwrap();
    assert_eq!(
        explorer.folder_context(0).file_color(b"blob"),
        Cache.color()
    );
}
