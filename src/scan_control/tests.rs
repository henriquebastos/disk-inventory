use super::*;
use crate::{
    Method,
    inventory::{Inventory, ScanOptions},
};
use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Barrier, atomic::AtomicUsize},
};

static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "scan-control-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
        fs::create_dir(&path).unwrap();
        fs::create_dir(path.join("tree")).unwrap();
        for i in 0..600 {
            fs::write(path.join(format!("tree/file-{i}")), b"fixture").unwrap();
        }
        Self(path)
    }
    fn create(&self, control: &ScanControl) -> io::Result<Inventory> {
        Inventory::create_controlled(
            &self.0.join("tree"),
            &self.0.join("map"),
            ScanOptions::default(),
            control,
        )
    }
    fn assert_unpublished(&self) {
        assert!(!self.0.join("map").exists());
        assert_eq!(
            fs::read_dir(&self.0).unwrap().count(),
            1,
            "no staging files left"
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn cancellation_before_and_during_collection_joins_workers_without_publication() {
    let fixture = Fixture::new();
    for workers in [1, 2, 4, 8] {
        for threshold in [0, 1, 257] {
            let control = ScanControl::new();
            if threshold == 0 {
                assert!(control.cancel());
            }
            *control.hook.lock().unwrap() = Some(Box::new(move |c| {
                if c.progress().items_examined >= threshold {
                    c.cancel();
                }
            }));
            let error = Inventory::create_controlled(
                &fixture.0.join("tree"),
                &fixture.0.join("map"),
                ScanOptions { workers },
                &control,
            )
            .unwrap_err();
            assert!(error.get_ref().unwrap().is::<ScanCancelled>());
            assert_eq!(control.progress().phase, ScanPhase::Cancelled);
            assert_eq!(control.progress().items_examined, threshold);
            fixture.assert_unpublished();
        }
    }
}

#[test]
fn accounting_and_serialization_cancellation_remove_only_owned_staging() {
    let fixture = Fixture::new();
    for phase in [ScanPhase::Accounting, ScanPhase::Saving] {
        for checkpoint in [1, 3, 8] {
            let control = ScanControl::new();
            let seen = AtomicUsize::new(0);
            *control.hook.lock().unwrap() = Some(Box::new(move |c| {
                if c.progress().phase == phase && seen.fetch_add(1, Ordering::Relaxed) == checkpoint
                {
                    c.cancel();
                }
            }));
            assert!(
                fixture
                    .create(&control)
                    .unwrap_err()
                    .get_ref()
                    .unwrap()
                    .is::<ScanCancelled>()
            );
            fixture.assert_unpublished();
        }
    }
}

#[test]
fn controlled_counts_are_monotonic_and_disabled_scans_keep_snapshot_bytes() {
    let fixture = Fixture::new();
    std::os::unix::fs::symlink("file-0", fixture.0.join("tree/excluded-link")).unwrap();
    let control = ScanControl::new();
    let previous = AtomicU64::new(0);
    *control.hook.lock().unwrap() = Some(Box::new(move |c| {
        let count = c.progress().items_examined;
        assert!(count >= previous.swap(count, Ordering::Relaxed));
    }));
    fixture.create(&control).unwrap();
    assert_eq!(control.progress().items_examined, 602);
    assert_eq!(control.progress().phase, ScanPhase::Committed);
    assert!(!control.cancel());
    let plain = fixture.0.join("plain");
    Inventory::create(&fixture.0.join("tree"), &plain, ScanOptions::default()).unwrap();
    assert_eq!(
        fs::read(plain).unwrap(),
        fs::read(fixture.0.join("map")).unwrap()
    );
    let unused = ScanControl::new();
    crate::scan(&fixture.0.join("tree"), Method::Bulk, 4).unwrap();
    assert_eq!(unused.progress().items_examined, 0);
    assert_eq!(unused.progress().phase, ScanPhase::Ready);
    assert!(fixture.create(&control).is_err(), "single-use");
    assert_eq!(control.progress().phase, ScanPhase::Committed);
}

#[test]
fn old_destination_and_concurrent_no_clobber_survive() {
    let fixture = Fixture::new();
    let output = fixture.0.join("map");
    fs::write(&output, b"old valid generation stand-in").unwrap();
    assert!(fixture.create(&ScanControl::new()).is_err());
    assert_eq!(fs::read(&output).unwrap(), b"old valid generation stand-in");
    fs::remove_file(&output).unwrap();
    let control = ScanControl::new();
    let path = output.clone();
    *control.hook.lock().unwrap() = Some(Box::new(move |c| {
        if c.progress().phase == ScanPhase::Saving && !path.exists() {
            fs::write(&path, b"concurrent destination").unwrap();
        }
    }));
    assert!(fixture.create(&control).is_err());
    assert_eq!(fs::read(&output).unwrap(), b"concurrent destination");
    assert_eq!(control.progress().phase, ScanPhase::Failed);
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 2);
}

#[test]
fn stop_and_commit_arbitrate_and_postpublication_errors_are_truthful() {
    for _ in 0..100 {
        let control = ScanControl::new();
        control.enter(ScanPhase::Saving).unwrap();
        let gate = Arc::new(Barrier::new(2));
        std::thread::scope(|scope| {
            let gate2 = gate.clone();
            let c = control.clone();
            let stop = scope.spawn(move || {
                gate2.wait();
                c.cancel()
            });
            gate.wait();
            let commit = control.commit();
            assert_ne!(stop.join().unwrap(), commit.is_ok());
            if commit.is_ok() {
                control.published();
                control.finish::<()>(&Err(io::Error::other("parent fsync failed")));
                assert_eq!(control.progress().phase, ScanPhase::PublishedFailure);
                assert!(!control.cancel());
            }
        });
    }
}

#[cfg(feature = "bridge")]
#[test]
fn bridge_control_polls_and_stops_independently_of_constructor() {
    use std::os::unix::ffi::OsStrExt;
    let fixture = Fixture::new();
    let control = ScanControl::new();
    let reached = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let once = AtomicBool::new(false);
    let (r, s) = (reached.clone(), release.clone());
    *control.hook.lock().unwrap() = Some(Box::new(move |c| {
        if c.progress().items_examined >= 257 && !once.swap(true, Ordering::Relaxed) {
            r.wait();
            s.wait();
        }
    }));
    std::thread::scope(|scope| {
        let c = control.clone();
        let root = fixture.0.join("tree").as_os_str().as_bytes().to_vec();
        let output = fixture.0.join("map").as_os_str().as_bytes().to_vec();
        let task = scope
            .spawn(move || crate::bridge::ExplorerSession::create_controlled(root, output, 4, c));
        reached.wait();
        assert_eq!(control.progress().phase, ScanPhase::Scanning);
        assert!(control.cancel());
        assert_eq!(control.progress().phase, ScanPhase::Stopping);
        release.wait();
        assert!(matches!(
            task.join().unwrap(),
            Err(crate::bridge::BridgeError::Cancelled)
        ));
    });
    fixture.assert_unpublished();
}
