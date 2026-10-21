//! What the engine asks of the operating system about other processes: whether
//! one is still running, its parent, its terminal, the ones running a named
//! program and, on macOS, its app. Everything else stays in the modules that
//! use it.

use std::path::PathBuf;

#[cfg(not(target_os = "macos"))]
mod linux;
#[cfg(not(target_os = "macos"))]
use linux as imp;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as imp;

#[cfg(target_os = "macos")]
pub use macos::{app_bundle, keychain_item_exists, keychain_password, KeychainError};

/// Whether `pid` is a running process. A process owned by another user still
/// counts, which is why `EPERM` means yes.
pub fn is_alive(pid: u32) -> bool {
    // 0 and anything past i32::MAX would address a process group, not a pid.
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists; nothing is sent.
    let rc = unsafe { libc::kill(pid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// The parent of `pid`, if it is still running.
pub fn parent(pid: u32) -> Option<u32> {
    imp::parent(pid)
}

/// The terminal `pid` is attached to, such as `/dev/pts/3` or `/dev/ttys003`.
pub fn tty(pid: u32) -> Option<PathBuf> {
    imp::tty(pid)
}

/// Every running process whose executable is named `name`, with its working
/// directory: which of several instances of a tool is on a given folder.
pub fn processes_named(name: &str) -> Vec<(u32, PathBuf)> {
    imp::processes_named(name)
}

/// The program that opens a file or URL with its default app.
pub const OPENER: &str = if cfg!(target_os = "macos") {
    "open"
} else {
    "xdg-open"
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_is_alive() {
        assert!(is_alive(std::process::id()));
    }

    #[test]
    fn process_groups_are_not_pids() {
        assert!(!is_alive(0));
        assert!(!is_alive(u32::MAX));
    }

    #[test]
    fn this_process_has_a_parent() {
        let parent = parent(std::process::id()).expect("a parent");
        assert!(parent > 0);
        assert!(is_alive(parent));
    }
}
