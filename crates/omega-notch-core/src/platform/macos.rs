//! Process details from libproc, and the login Keychain.

use std::ffi::c_void;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use security_framework::item::{ItemClass, ItemSearchOptions, Limit, SearchResult};

/// `errSecItemNotFound`
const ITEM_NOT_FOUND: i32 = -25300;
/// `errSecUserCanceled` and `errSecAuthFailed`: the user said no to the prompt.
const DENIED: [i32; 2] = [-128, -25293];

/// One of `proc_pidinfo`'s plain-data records for `pid`.
fn pid_info<T>(pid: u32, flavor: libc::c_int) -> Option<T> {
    let pid = libc::c_int::try_from(pid).ok().filter(|p| *p > 0)?;
    // SAFETY: only used with libproc's records, which are plain old data, so
    // all zeroes is a valid value.
    let mut info: T = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<T>() as libc::c_int;
    // SAFETY: the buffer is a T and `size` is its exact size.
    let written =
        unsafe { libc::proc_pidinfo(pid, flavor, 0, &mut info as *mut T as *mut c_void, size) };
    (written == size).then_some(info)
}

/// Uses the short record, which macOS gives out for any process: the full
/// one is refused for another user's, and a terminal session runs under
/// root's `/usr/bin/login`.
pub fn parent(pid: u32) -> Option<u32> {
    pid_info::<libc::proc_bsdshortinfo>(pid, libc::PROC_PIDT_SHORTBSDINFO)
        .map(|info| info.pbsi_ppid)
}

pub fn tty(pid: u32) -> Option<PathBuf> {
    let dev = pid_info::<libc::proc_bsdinfo>(pid, libc::PROC_PIDTBSDINFO)?.e_tdev;
    // NODEV: no controlling terminal.
    if dev == u32::MAX {
        return None;
    }
    // devname() shares one static buffer between threads; looking the device
    // up in /dev is just as quick and safe.
    std::fs::read_dir("/dev")
        .ok()?
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("ttys"))
        .map(|e| e.path())
        .find(|p| p.metadata().is_ok_and(|m| m.rdev() == u64::from(dev)))
}

/// The `.app` bundle that `pid` runs from, such as
/// `/Applications/iTerm.app`, or `None` for a bare command-line program.
pub fn app_bundle(pid: u32) -> Option<PathBuf> {
    let pid = libc::c_int::try_from(pid).ok().filter(|p| *p > 0)?;
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the buffer is as large as the size passed for it.
    let len = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if len <= 0 {
        return None;
    }
    buf.truncate(len as usize);
    let exe = PathBuf::from(String::from_utf8(buf).ok()?);
    // The outermost bundle, so a helper inside an app (VS Code's terminal
    // host, for one) resolves to the app itself.
    exe.ancestors()
        .filter(|p| p.extension().is_some_and(|e| e == "app"))
        .last()
        .map(Path::to_path_buf)
}

#[derive(Debug)]
pub enum KeychainError {
    NotFound,
    /// The user turned down the Keychain prompt.
    Denied,
    Other(String),
}

/// The secret of the generic password item named `service`. macOS asks the
/// user first unless they already chose "Always Allow" for this program.
/// Blocks while that prompt is up.
pub fn keychain_password(service: &str) -> Result<Vec<u8>, KeychainError> {
    let results = ItemSearchOptions::new()
        .class(ItemClass::generic_password())
        .service(service)
        .load_data(true)
        .limit(Limit::Max(1))
        .search()
        .map_err(|err| match err.code() {
            ITEM_NOT_FOUND => KeychainError::NotFound,
            code if DENIED.contains(&code) => KeychainError::Denied,
            _ => KeychainError::Other(err.to_string()),
        })?;
    results
        .into_iter()
        .find_map(|r| match r {
            SearchResult::Data(data) => Some(data),
            _ => None,
        })
        .ok_or(KeychainError::NotFound)
}

/// Whether a generic password item named `service` exists, without reading
/// its secret, so it never prompts.
pub fn keychain_item_exists(service: &str) -> bool {
    ItemSearchOptions::new()
        .class(ItemClass::generic_password())
        .service(service)
        .load_attributes(true)
        .limit(Limit::Max(1))
        .search()
        .is_ok_and(|r| !r.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_keychain_item_is_not_found() {
        let service = "omega-notch-test-item-that-does-not-exist";
        assert!(!keychain_item_exists(service));
        assert!(matches!(
            keychain_password(service),
            Err(KeychainError::NotFound)
        ));
    }

    #[test]
    fn root_processes_still_have_a_parent() {
        // launchd runs as root, like the `login` between a terminal and its
        // shell; the walk up to the terminal must not stop there.
        assert_eq!(parent(1), Some(0));
    }

    #[test]
    fn command_line_programs_have_no_bundle() {
        // The test binary lives in target/, not in an .app.
        assert_eq!(app_bundle(std::process::id()), None);
    }
}
