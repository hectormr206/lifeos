//! Single-instance pidfile guard for lifeosd.
//!
//! Acquires an exclusive advisory lock on `/run/user/<uid>/lifeos/lifeosd.pid`
//! so only one daemon runs per user session. The lock is held for the lifetime
//! of the returned [`PidFileGuard`]; dropping the guard (or process exit)
//! releases it. Stale pidfiles from crashed processes are overwritten.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;

#[cfg(test)]
mod single_instance_tests;

/// Reasons lock acquisition can fail without being a hard error.
pub enum LockOutcome {
    /// Lock acquired. Hold the guard for the process lifetime.
    Acquired(PidFileGuard),
    /// Another live instance holds the lock.
    AlreadyRunning(i32),
}

/// RAII guard owning the locked pidfile descriptor. Drop releases the flock.
pub struct PidFileGuard {
    _file: File,
    path: PathBuf,
}

impl Drop for PidFileGuard {
    fn drop(&mut self) {
        // Best-effort cleanup so the next start doesn't see a stale PID.
        // The flock is released automatically when the fd closes.
        let _ = std::fs::remove_file(&self.path);
    }
}

fn pidfile_path() -> PathBuf {
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/run/user/{}/lifeos/lifeosd.pid", uid))
}

fn process_alive(pid: i32) -> bool {
    if pid <= 1 {
        return false;
    }
    // kill(pid, 0) returns 0 if the process exists and we can signal it,
    // -1 with errno=ESRCH if it doesn't exist. EPERM means it exists but
    // we can't signal it — still alive for our purposes.
    let rc = unsafe { libc::kill(pid, 0) };
    if rc == 0 {
        return true;
    }
    let err = std::io::Error::last_os_error();
    err.raw_os_error() == Some(libc::EPERM)
}

/// Try to acquire the single-instance lock. Returns either an owned guard or
/// a report that another live instance is already running.
pub fn acquire_lock() -> std::io::Result<LockOutcome> {
    let path = pidfile_path();
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
    }

    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&path)?;

    let fd = file.as_raw_fd();
    let rc = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        let err = std::io::Error::last_os_error();
        if matches!(err.raw_os_error(), Some(libc::EWOULDBLOCK)) {
            let mut buf = String::new();
            file.read_to_string(&mut buf).ok();
            let pid = buf.trim().parse::<i32>().unwrap_or(0);
            if pid > 0 && process_alive(pid) {
                return Ok(LockOutcome::AlreadyRunning(pid));
            }
            // Holder is gone but kernel still owns the lock (rare race).
            // Treat as already-running to avoid stomping; next start cleans up.
            return Ok(LockOutcome::AlreadyRunning(pid.max(0)));
        }
        return Err(err);
    }

    // We own the lock. Overwrite any stale PID with our own.
    file.seek(SeekFrom::Start(0))?;
    file.set_len(0)?;
    let pid = unsafe { libc::getpid() };
    writeln!(file, "{}", pid)?;
    file.flush()?;

    Ok(LockOutcome::Acquired(PidFileGuard { _file: file, path }))
}
