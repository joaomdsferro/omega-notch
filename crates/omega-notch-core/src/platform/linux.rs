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
