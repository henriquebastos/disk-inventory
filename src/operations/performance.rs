use super::*;
use std::{
    alloc::{GlobalAlloc, Layout, System},
    sync::atomic::{AtomicUsize, Ordering},
    time::{Duration, Instant},
};

// Test-only requested-allocation counters; these exclude malloc metadata, ObjC,
// and allocator retention. Unlike process peak RSS they reset per operation.
struct MeasuredAllocator;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
fn allocated(size: usize) {
    let live = LIVE.fetch_add(size, Ordering::Relaxed) + size;
    PEAK.fetch_max(live, Ordering::Relaxed);
}
// SAFETY: delegates unchanged layouts/pointers to System; atomics only observe sizes.
unsafe impl GlobalAlloc for MeasuredAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: forwarded allocator preconditions.
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            allocated(layout.size());
        }
        ptr
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        // SAFETY: forwarded allocator preconditions.
        unsafe {
            System.dealloc(ptr, layout);
        }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        // SAFETY: forwarded allocator preconditions.
        let ptr = unsafe { System.realloc(ptr, layout, size) };
        if !ptr.is_null() {
            if size > layout.size() {
                allocated(size - layout.size());
            } else {
                LIVE.fetch_sub(layout.size() - size, Ordering::Relaxed);
            }
        }
        ptr
    }
}
#[global_allocator]
static ALLOCATOR: MeasuredAllocator = MeasuredAllocator;
struct TimedMemory {
    inner: MemoryFileSystem,
    elapsed: Duration,
}
impl FileSystem for TimedMemory {
    type Pin = <MemoryFileSystem as FileSystem>::Pin;
    fn pin(&mut self, target: &Target) -> io::Result<Self::Pin> {
        self.inner.pin(target)
    }
    fn snapshot_identity(&self) -> Option<Identity> {
        self.inner.snapshot_identity()
    }
    fn metadata(&mut self, path: &Path) -> io::Result<LiveMetadata> {
        let t = Instant::now();
        let r = self.inner.metadata(path);
        self.elapsed += t.elapsed();
        r
    }
    fn read_directory(&mut self, target: &Target) -> io::Result<Vec<DirectoryEntry>> {
        let t = Instant::now();
        let r = self.inner.read_directory(target);
        self.elapsed += t.elapsed();
        r
    }
    fn trash(&mut self, target: &Target, pin: &Self::Pin) -> Mutation {
        let t = Instant::now();
        let r = self.inner.trash(target, pin);
        self.elapsed += t.elapsed();
        r
    }
    fn refuse_protected_within(&mut self, target: &Target) -> io::Result<()> {
        let t = Instant::now();
        let r = self.inner.refuse_protected_within(target);
        self.elapsed += t.elapsed();
        r
    }
    fn remove(
        &mut self,
        target: &Target,
        pin: &Self::Pin,
        control: Option<&ScanControl>,
    ) -> Mutation {
        let t = Instant::now();
        let r = self.inner.remove(target, pin, control);
        self.elapsed += t.elapsed();
        r
    }
    fn classify_destination(&mut self, path: &Path, root: Identity) -> DestinationScope {
        let t = Instant::now();
        let r = self.inner.classify_destination(path, root);
        self.elapsed += t.elapsed();
        r
    }
}
fn timed(s: OperationSession<MemoryFileSystem>) -> OperationSession<TimedMemory> {
    OperationSession {
        explorer: s.explorer,
        filesystem: TimedMemory {
            inner: s.filesystem,
            elapsed: Duration::ZERO,
        },
        identities: s.identities,
        state: s.state,
        activity: s.activity,
        work: s.work,
        groups: s.groups,
        observations: s.observations,
        baselines: s.baselines,
        unresolved_groups: s.unresolved_groups,
        survivor_groups: s.survivor_groups,
        sort: s.sort,
        issues: s.issues,
        prefetched: s.prefetched,
    }
}
fn measure<R>(
    s: &mut OperationSession<TimedMemory>,
    label: &str,
    action: impl FnOnce(&mut OperationSession<TimedMemory>) -> R,
) -> R {
    s.filesystem.elapsed = Duration::ZERO;
    let before = LIVE.load(Ordering::Relaxed);
    PEAK.store(before, Ordering::Relaxed);
    let t = Instant::now();
    let result = action(s);
    let total = t.elapsed();
    let adapter = s.filesystem.elapsed;
    let after = LIVE.load(Ordering::Relaxed);
    let peak = PEAK.load(Ordering::Relaxed);
    println!(
        "{label} total_us={:.3} adapter_us={:.3} core_us={:.3} live_before={} live_after={} peak_extra={} temporary_above_retained={}",
        total.as_secs_f64() * 1e6,
        adapter.as_secs_f64() * 1e6,
        total.saturating_sub(adapter).as_secs_f64() * 1e6,
        before,
        after,
        peak.saturating_sub(before),
        peak.saturating_sub(before.max(after))
    );
    result
}
#[test]
#[ignore = "release-only synthetic scale measurement, no source scan"]
fn operations_release_performance() {
    let count = std::env::var("OPERATIONS_ENTRIES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3_000_000);
    let start = Instant::now();
    let original = session();
    let mut map = original.explorer.map;
    for i in 0..count {
        add(
            &mut map,
            3,
            format!("other-{i:08}").as_bytes(),
            &meta(1000 + i as u64, Kind::File, 4),
        );
    }
    map.aggregate().unwrap();
    let fixture_ms = start.elapsed().as_secs_f64() * 1000.;
    let indexing = Instant::now();
    let explorer = Explorer::from_map(map).unwrap();
    let explorer_ms = indexing.elapsed().as_secs_f64() * 1000.;
    let indexing = Instant::now();
    let mut s = timed(OperationSession::new(explorer, original.filesystem));
    let identity_ms = indexing.elapsed().as_secs_f64() * 1000.;
    println!(
        "unrelated_startup fixture_ms={fixture_ms:.3} explorer_index_ms={explorer_ms:.3} identity_index_ms={identity_ms:.3}"
    );
    println!(
        "unrelated_entries={count} startup_ms={:.3} arena_bytes={} explorer_index_bytes={} identity_base_bytes={} rust_live={} process_peak_rss={}",
        start.elapsed().as_secs_f64() * 1000.,
        s.explorer.storage_stats().arena_bytes,
        s.explorer.storage_stats().index_bytes,
        s.identity_index_bytes(),
        LIVE.load(Ordering::Relaxed),
        crate::native::peak_rss().unwrap()
    );
    for iteration in 0..3 {
        if iteration > 0 {
            s.filesystem
                .inner
                .insert("/scope/a/new", meta(10 + iteration, Kind::File, 100));
            let r = measure(&mut s, &format!("small_refresh_{iteration}"), |s| {
                s.refresh_directory(s.explorer.handle(1)).unwrap()
            });
            println!("work={:?}", r.work);
        }
        let selected = s
            .explorer
            .children(s.explorer.handle(1), 0, 10)
            .unwrap()
            .entries[0]
            .handle;
        let c = s.prepare(selected, Action::PermanentlyDelete).unwrap();
        let r = measure(&mut s, &format!("small_delete_{iteration}"), |s| {
            s.execute(c).unwrap()
        });
        println!("work={:?}", r.update.work);
        let l = measure(&mut s, "small_layout", |s| {
            s.explorer
                .layout(s.explorer.root_handle(), options())
                .unwrap()
        });
        println!(
            "tiles={} groups={} work={:?}",
            l.tiles.len(),
            l.groups.len(),
            l.work
        );
    }
    drop(s);
    let start = Instant::now();
    let count = 1_000_000;
    let mut map = empty();
    let mut fs = MemoryFileSystem::default();
    let root = meta(1, Kind::Dir, 0);
    add(&mut map, 0, b"", &root);
    fs.insert("/scope", root);
    for i in 0..count {
        let name = format!("file-{i:08}");
        let m = meta(i + 2, Kind::File, 4);
        add(&mut map, 0, name.as_bytes(), &m);
        fs.insert(format!("/scope/{name}"), m);
    }
    map.aggregate().unwrap();
    let fixture_ms = start.elapsed().as_secs_f64() * 1000.;
    let indexing = Instant::now();
    let explorer = Explorer::from_map(map).unwrap();
    let explorer_ms = indexing.elapsed().as_secs_f64() * 1000.;
    let indexing = Instant::now();
    let mut s = timed(OperationSession::new(explorer, fs));
    let identity_ms = indexing.elapsed().as_secs_f64() * 1000.;
    println!(
        "fanout_startup fixture_ms={fixture_ms:.3} explorer_index_ms={explorer_ms:.3} identity_index_ms={identity_ms:.3}"
    );
    println!(
        "million_fanout startup_ms={:.3} arena_bytes={} explorer_index_bytes={} identity_base_bytes={} rust_live={} process_peak_rss={}",
        start.elapsed().as_secs_f64() * 1000.,
        s.explorer.storage_stats().arena_bytes,
        s.explorer.storage_stats().index_bytes,
        s.identity_index_bytes(),
        LIVE.load(Ordering::Relaxed),
        crate::native::peak_rss().unwrap()
    );
    for iteration in 0..3 {
        let selected = s
            .explorer
            .children(s.explorer.root_handle(), 0, 1)
            .unwrap()
            .entries[0]
            .handle;
        let c = s.prepare(selected, Action::PermanentlyDelete).unwrap();
        let r = measure(&mut s, &format!("fanout_delete_{iteration}"), |s| {
            s.execute(c).unwrap()
        });
        println!("work={:?}", r.update.work);
        let l = measure(&mut s, "fanout_layout", |s| {
            s.explorer
                .layout(s.explorer.root_handle(), options())
                .unwrap()
        });
        println!("tiles={} work={:?}", l.tiles.len(), l.work);
        // One live file changes; refreshing this explicitly selected million-child
        // directory must enumerate its fanout and reorder only that parent's list.
        let changed = 500_000 + iteration;
        s.filesystem.inner.insert(
            format!("/scope/file-{changed:08}"),
            meta(changed + 2, Kind::File, 8 + iteration),
        );
        let r = measure(&mut s, &format!("fanout_refresh_{iteration}"), |s| {
            s.refresh_directory(s.explorer.root_handle()).unwrap()
        });
        println!(
            "work={:?} process_peak_rss={}",
            r.work,
            crate::native::peak_rss().unwrap()
        );
    }
}
