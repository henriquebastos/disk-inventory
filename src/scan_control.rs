//! Single-use, independently polled control for snapshot creation.
use std::{
    io,
    sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "bridge", derive(uniffi::Enum))]
#[repr(u8)]
pub enum ScanPhase {
    Ready,
    Scanning,
    Accounting,
    Saving,
    Stopping,
    Committing,
    Committed,
    PreparingView,
    Complete,
    Cancelled,
    Failed,
    PublishedFailure,
}
impl ScanPhase {
    fn cancellable(self) -> bool {
        matches!(
            self,
            Self::Ready | Self::Scanning | Self::Accounting | Self::Saving
        )
    }
}
#[derive(Clone, Debug)]
#[cfg_attr(feature = "bridge", derive(uniffi::Record))]
pub struct ScanProgress {
    pub phase: ScanPhase,
    pub items_examined: u64,
    pub cancellable: bool,
}
#[derive(Debug)]
pub struct ScanCancelled;
impl std::fmt::Display for ScanCancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("scan cancelled before publication")
    }
}
impl std::error::Error for ScanCancelled {}

#[cfg(test)]
type CheckpointHook = Box<dyn Fn(&ScanControl) + Send + Sync>;

#[cfg_attr(feature = "bridge", derive(uniffi::Object))]
pub struct ScanControl {
    phase: AtomicU8,
    examined: AtomicU64,
    claimed: AtomicBool,
    #[cfg(test)]
    pub(crate) hook: std::sync::Mutex<Option<CheckpointHook>>,
}
impl Default for ScanControl {
    fn default() -> Self {
        Self {
            phase: AtomicU8::new(ScanPhase::Ready as u8),
            examined: AtomicU64::new(0),
            claimed: AtomicBool::new(false),
            #[cfg(test)]
            hook: std::sync::Mutex::new(None),
        }
    }
}
#[cfg_attr(feature = "bridge", uniffi::export)]
impl ScanControl {
    #[cfg_attr(feature = "bridge", uniffi::constructor)]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self::default())
    }
    pub fn progress(&self) -> ScanProgress {
        let phase = self.phase();
        ScanProgress {
            phase,
            items_examined: self.examined.load(Ordering::Acquire),
            cancellable: phase.cancellable(),
        }
    }
    /// True only when Stop won against publication (or was already requested).
    pub fn cancel(&self) -> bool {
        loop {
            let phase = self.phase();
            if phase == ScanPhase::Stopping {
                return true;
            }
            if !phase.cancellable() {
                return false;
            }
            if self
                .phase
                .compare_exchange(
                    phase as u8,
                    ScanPhase::Stopping as u8,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                return true;
            }
        }
    }
}
impl ScanControl {
    fn phase(&self) -> ScanPhase {
        use ScanPhase::*;
        [
            Ready,
            Scanning,
            Accounting,
            Saving,
            Stopping,
            Committing,
            Committed,
            PreparingView,
            Complete,
            Cancelled,
            Failed,
            PublishedFailure,
        ][self.phase.load(Ordering::Acquire) as usize]
    }
    pub(crate) fn begin(&self) -> io::Result<()> {
        if self.claimed.swap(true, Ordering::AcqRel) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "scan control is single-use",
            ));
        }
        Ok(())
    }
    pub(crate) fn check(&self) -> io::Result<()> {
        #[cfg(test)]
        if let Some(hook) = &*self.hook.lock().unwrap() {
            hook(self);
        }
        if self.phase() == ScanPhase::Stopping {
            Err(io::Error::new(io::ErrorKind::Interrupted, ScanCancelled))
        } else {
            Ok(())
        }
    }
    pub(crate) fn enter(&self, next: ScanPhase) -> io::Result<()> {
        loop {
            self.check()?;
            let current = self.phase();
            if current == ScanPhase::Stopping {
                continue;
            }
            if self
                .phase
                .compare_exchange(
                    current as u8,
                    next as u8,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                return self.check();
            }
        }
    }
    pub(crate) fn examined(&self, count: usize) {
        self.examined.fetch_add(count as u64, Ordering::Release);
    }
    /// The CAS arbitrates Stop against the namespace operation. Once won, Stop
    /// is disabled even while that syscall is in flight; failure is not cancellation.
    pub(crate) fn commit(&self) -> io::Result<()> {
        self.check()?;
        self.phase
            .compare_exchange(
                ScanPhase::Saving as u8,
                ScanPhase::Committing as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| io::Error::new(io::ErrorKind::Interrupted, ScanCancelled))?;
        Ok(())
    }
    pub(crate) fn published(&self) {
        self.set(ScanPhase::Committed);
    }
    pub(crate) fn set(&self, phase: ScanPhase) {
        self.phase.store(phase as u8, Ordering::Release);
    }
    pub(crate) fn finish<T>(&self, result: &io::Result<T>) {
        if let Err(error) = result {
            self.set(
                if error.get_ref().is_some_and(|e| e.is::<ScanCancelled>()) {
                    ScanPhase::Cancelled
                } else if matches!(
                    self.phase(),
                    ScanPhase::Committed | ScanPhase::PreparingView
                ) {
                    ScanPhase::PublishedFailure
                } else {
                    ScanPhase::Failed
                },
            );
        }
    }
}
pub(crate) fn check(control: Option<&ScanControl>) -> io::Result<()> {
    if let Some(control) = control {
        control.check()?;
    }
    Ok(())
}
#[cfg(test)]
mod tests;
