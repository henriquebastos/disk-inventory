//! Streaming encoders. Human paths use UTF-8 replacement; hex paths are authoritative.
use crate::{Kind, hex, inventory::Inventory};
use std::io::{self, Write};

#[derive(Clone, Copy, Debug)]
pub enum Format {
    Csv,
    Jsonl,
    Tsv,
}
const HEADER: [&str; 6] = [
    "path",
    "path_hex",
    "kind",
    "allocated_bytes",
    "accounted_bytes",
    "subtree_bytes",
];

/// CSV/TSV always include a header; JSONL has one object per entry, no header.
/// Paths are relative, with an empty path for the root. Rows retain snapshot order.
pub fn export(inventory: &Inventory, format: Format, mut out: impl Write) -> io::Result<()> {
    match format {
        Format::Csv => writeln!(out, "{}", HEADER.join(","))?,
        Format::Tsv => writeln!(out, "{}", HEADER.join("\t"))?,
        Format::Jsonl => {}
    }
    for entry in inventory.entries() {
        let path = String::from_utf8_lossy(&entry.relative_path);
        let path_hex = hex(&entry.relative_path);
        let kind = match entry.kind {
            Kind::File => "file",
            Kind::Dir => "directory",
            Kind::Other => "other",
            Kind::Symlink => "symlink",
        };
        match format {
            Format::Csv => {
                // Always quote human paths, doubling embedded quotes (including multiline fields).
                writeln!(
                    out,
                    "\"{}\",{},{},{},{},{}",
                    path.replace('"', "\"\""),
                    path_hex,
                    kind,
                    entry.allocated_bytes,
                    entry.accounted_bytes,
                    entry.subtree_bytes
                )?;
            }
            Format::Tsv => writeln!(
                out,
                "{}\t{}\t{}\t{}\t{}\t{}",
                tsv_string(&path),
                path_hex,
                kind,
                entry.allocated_bytes,
                entry.accounted_bytes,
                entry.subtree_bytes
            )?,
            Format::Jsonl => writeln!(
                out,
                "{{\"path\":{},\"path_hex\":\"{}\",\"kind\":\"{}\",\"allocated_bytes\":{},\"accounted_bytes\":{},\"subtree_bytes\":{}}}",
                json_string(&path),
                path_hex,
                kind,
                entry.allocated_bytes,
                entry.accounted_bytes,
                entry.subtree_bytes
            )?,
        }
    }
    Ok(())
}

pub(crate) fn json_string(value: &str) -> String {
    let mut result = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\u{00}'..='\u{1f}' => {
                use std::fmt::Write;
                write!(result, "\\u{:04x}", c as u32).unwrap();
            }
            _ => result.push(c),
        }
    }
    result.push('"');
    result
}
fn tsv_string(value: &str) -> String {
    let mut result = String::new();
    for c in value.chars() {
        match c {
            '\\' => result.push_str("\\\\"),
            '\t' => result.push_str("\\t"),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            _ => result.push(c),
        }
    }
    result
}

/// One JSON object describing saved data only; no source-tree access.
pub fn info(inventory: &Inventory, mut out: impl Write) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let root = inventory.root().as_os_str().as_bytes();
    let c = inventory.counters();
    writeln!(
        out,
        "{{\"root\":{},\"root_hex\":\"{}\",\"entries\":{},\"subtree_bytes\":{},\"partial\":{},\"errors\":{},\"skipped_symlinks\":{},\"skipped_mounts\":{},\"skipped_firmlinks\":{},\"duplicate_dirs\":{},\"metadata_fallbacks\":{}}}",
        json_string(&String::from_utf8_lossy(root)),
        hex(root),
        inventory.len(),
        inventory.subtree_bytes(),
        inventory.is_partial(),
        c.errors,
        c.symlinks,
        c.mounts,
        c.firmlinks,
        c.duplicate_dirs,
        c.metadata_fallbacks
    )
}
