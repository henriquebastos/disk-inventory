use disk_map_bench::{
    export::{self, Format},
    invalid,
    inventory::{IncompleteSync, Inventory, ScanOptions},
};
use std::{
    ffi::OsString,
    io::{self, Write},
    path::PathBuf,
};

const USAGE: &str = "disk-inventory create ABS_ROOT --output FILE [--workers 1|2|4|8]\ndisk-inventory sync FILE [--workers 1|2|4|8]\ndisk-inventory info FILE\ndisk-inventory export FILE --format csv|jsonl|tsv\nNative bulk collection; default workers: 4. Sync omits only the current snapshot and its hardlinks.\nCSV/TSV include headers; JSONL does not. Paths are relative; root path is empty.\nExit: 0 complete, 2 partial, 1 fatal. Only sync refreshes saved data.";

enum Command {
    Create {
        root: PathBuf,
        output: PathBuf,
        options: ScanOptions,
    },
    Sync {
        file: PathBuf,
        options: ScanOptions,
    },
    Info(PathBuf),
    Export {
        file: PathBuf,
        format: Format,
    },
    Help,
}
fn parse(args: impl IntoIterator<Item = OsString>) -> io::Result<Command> {
    let mut args = args.into_iter();
    let command = args.next().ok_or_else(|| invalid(USAGE))?;
    if matches!(command.to_str(), Some("--help" | "-h")) && args.next().is_none() {
        return Ok(Command::Help);
    }
    let command = command.to_str().ok_or_else(|| invalid(USAGE))?;
    if !["create", "sync", "info", "export"].contains(&command) {
        return Err(invalid(USAGE));
    }
    let file = PathBuf::from(
        args.next()
            .ok_or_else(|| invalid("missing root or snapshot file"))?,
    );
    let mut output = None;
    let mut workers = None;
    let mut format = None;
    while let Some(flag) = args.next() {
        match flag.to_str() {
            Some("--output") if command == "create" && output.is_none() => {
                output = Some(PathBuf::from(
                    args.next().ok_or_else(|| invalid("missing output file"))?,
                ));
            }
            Some("--workers") if matches!(command, "create" | "sync") && workers.is_none() => {
                workers = Some(match args.next().as_deref().and_then(|s| s.to_str()) {
                    Some("1") => 1,
                    Some("2") => 2,
                    Some("4") => 4,
                    Some("8") => 8,
                    _ => return Err(invalid("workers must be 1, 2, 4, or 8")),
                });
            }
            Some("--format") if command == "export" && format.is_none() => {
                format = Some(match args.next().as_deref().and_then(|s| s.to_str()) {
                    Some("csv") => Format::Csv,
                    Some("jsonl") => Format::Jsonl,
                    Some("tsv") => Format::Tsv,
                    _ => return Err(invalid("format must be csv, jsonl, or tsv")),
                });
            }
            _ => return Err(invalid("unknown, duplicate, or misplaced argument")),
        }
    }
    let options = ScanOptions {
        workers: workers.unwrap_or(4),
    };
    Ok(match command {
        "create" => Command::Create {
            root: file,
            output: output.ok_or_else(|| invalid("--output required"))?,
            options,
        },
        "sync" => Command::Sync { file, options },
        "info" => Command::Info(file),
        "export" => Command::Export {
            file,
            format: format.ok_or_else(|| invalid("--format required"))?,
        },
        _ => unreachable!(),
    })
}
fn run() -> io::Result<u8> {
    let command = parse(std::env::args_os().skip(1))?;
    if matches!(command, Command::Help) {
        eprintln!("{USAGE}");
        return Ok(0);
    }
    let inventory = match &command {
        Command::Create {
            root,
            output,
            options,
        } => Inventory::create(root, output, *options)?,
        Command::Sync { file, options } => Inventory::sync(file, *options)?,
        Command::Info(file) | Command::Export { file, .. } => Inventory::open(file)?,
        Command::Help => unreachable!(),
    };
    let status = if inventory.is_partial() {
        eprintln!(
            "disk-inventory: warning: partial inventory ({} scan errors); inaccessible subtrees are not empty",
            inventory.counters().errors
        );
        2
    } else {
        0
    };
    let mut out = io::BufWriter::new(io::stdout().lock());
    let result = match command {
        Command::Export { format, .. } => export::export(&inventory, format, &mut out),
        _ => export::info(&inventory, &mut out),
    }
    .and_then(|()| out.flush());
    match result {
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(status),
        result => result.map(|()| status),
    }
}
fn main() -> std::process::ExitCode {
    match run() {
        Ok(status) => std::process::ExitCode::from(status),
        Err(error) => {
            let partial = error.get_ref().is_some_and(|e| e.is::<IncompleteSync>());
            eprintln!("disk-inventory: {error}");
            std::process::ExitCode::from(if partial { 2 } else { 1 })
        }
    }
}
