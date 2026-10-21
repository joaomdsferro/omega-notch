//! Process details from `/proc`.

use std::path::PathBuf;

pub fn parent(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ppid …`; comm may hold spaces or parentheses.
    let rest = &stat[stat.rfind(')')? + 1..];
    rest.split_whitespace().nth(1)?.parse().ok()
}

pub fn tty(pid: u32) -> Option<PathBuf> {
    let tty = std::fs::read_link(format!("/proc/{pid}/fd/0")).ok()?;
    tty.starts_with("/dev/pts").then_some(tty)
}

/// The kernel caps `comm` at 15 characters, which every program here fits.
pub fn processes_named(name: &str) -> Vec<(u32, PathBuf)> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let pid = entry.file_name().to_str()?.parse::<u32>().ok()?;
            let comm = std::fs::read_to_string(entry.path().join("comm")).ok()?;
            if comm.trim() != name {
                return None;
            }
            let cwd = std::fs::read_link(entry.path().join("cwd")).ok()?;
            Some((pid, cwd))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_this_process_with_its_working_directory() {
        let name = std::fs::read_to_string("/proc/self/comm").unwrap();
        let found = processes_named(name.trim());
        let me = std::process::id();
        let mine = found
            .iter()
            .find(|(pid, _)| *pid == me)
            .expect("this process");
        assert!(mine.1.is_absolute());
    }
}
