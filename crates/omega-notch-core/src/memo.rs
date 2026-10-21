//! Per-file results worth recomputing only when the file changes.

use std::collections::HashMap;
use std::fs::Metadata;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

type Stamp = (SystemTime, u64);

/// Results keyed by path and remembered with the file's mtime and size, so a
/// pass over many unchanged files reads none of them again. Files a pass did
/// not visit are forgotten when it ends.
pub(crate) struct FileMemo<T> {
    kept: HashMap<PathBuf, (Stamp, T)>,
    seen: HashMap<PathBuf, (Stamp, T)>,
}

impl<T> Default for FileMemo<T> {
    fn default() -> Self {
        Self {
            kept: HashMap::new(),
            seen: HashMap::new(),
        }
    }
}

impl<T: Clone> FileMemo<T> {
    pub fn get(&mut self, path: &Path, meta: &Metadata, compute: impl FnOnce() -> T) -> T {
        let Ok(modified) = meta.modified() else {
            return compute();
        };
        let stamp = (modified, meta.len());
        if let Some((seen, value)) = self.seen.get(path) {
            if *seen == stamp {
                return value.clone();
            }
        }
        let value = match self.kept.remove(path) {
            Some((kept, value)) if kept == stamp => value,
            _ => compute(),
        };
        self.seen.insert(path.to_path_buf(), (stamp, value.clone()));
        value
    }

    pub fn finish_pass(&mut self) {
        self.kept = std::mem::take(&mut self.seen);
    }
}

#[cfg(test)]
mod tests {
    use super::FileMemo;
    use std::cell::Cell;

    #[test]
    fn recomputes_only_when_the_file_changes() {
        let dir = std::env::temp_dir().join(format!("omega-memo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.jsonl");
        std::fs::write(&path, "one").unwrap();

        let mut memo = FileMemo::default();
        let calls = Cell::new(0);
        let read = |memo: &mut FileMemo<usize>| {
            let meta = std::fs::metadata(&path).unwrap();
            let value = memo.get(&path, &meta, || {
                calls.set(calls.get() + 1);
                std::fs::read_to_string(&path).unwrap().len()
            });
            memo.finish_pass();
            value
        };

        assert_eq!(read(&mut memo), 3);
        assert_eq!(read(&mut memo), 3);
        assert_eq!(calls.get(), 1);

        std::fs::write(&path, "three").unwrap();
        assert_eq!(read(&mut memo), 5);
        assert_eq!(calls.get(), 2);

        // A pass that skips the file forgets it.
        memo.finish_pass();
        assert_eq!(read(&mut memo), 5);
        assert_eq!(calls.get(), 3);

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
