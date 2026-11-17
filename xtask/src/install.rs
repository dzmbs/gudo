//! Puts build outputs in place as new files renamed over the old ones, never by writing into
//! a file something may be running: macOS keeps a running binary's code signature with its
//! vnode, and kills a binary rewritten in place when it next launches.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// Copies `source` to `dest`, mode included.
pub fn copy_into_place(source: &Path, dest: &Path) -> io::Result<()> {
    let staged = Staged::new(dest);
    fs::copy(source, &staged.0)?;
    staged.rename_over(dest)
}

/// Writes `contents` to `dest`.
pub fn write_into_place(dest: &Path, contents: &[u8]) -> io::Result<()> {
    let staged = Staged::new(dest);
    let mut file = fs::File::create(&staged.0)?;
    file.write_all(contents)?;
    file.sync_all()?;
    staged.rename_over(dest)
}

/// A file next to the destination, removed unless renamed over it.
struct Staged(PathBuf);

impl Staged {
    fn new(dest: &Path) -> Self {
        let name = dest.file_name().unwrap_or_default().to_string_lossy();
        Self(dest.with_file_name(format!(".{name}.staged-{}", std::process::id())))
    }

    fn rename_over(self, dest: &Path) -> io::Result<()> {
        fs::rename(&self.0, dest)?;
        std::mem::forget(self);
        Ok(())
    }
}

impl Drop for Staged {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    use super::*;

    fn inode(path: &Path) -> u64 {
        fs::metadata(path).unwrap().ino()
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn a_helper_is_replaced_by_a_new_file_never_written_over() {
        let dir = tempfile::tempdir().unwrap();
        let built = dir.path().join("built");
        fs::write(&built, b"new build").unwrap();
        fs::set_permissions(&built, fs::Permissions::from_mode(0o755)).unwrap();
        let out = dir.path().join("out");
        fs::create_dir(&out).unwrap();
        let dest = out.join("gudo-hostd");
        fs::write(&dest, b"running build").unwrap();
        let running = inode(&dest);

        copy_into_place(&built, &dest).unwrap();
        assert_eq!(fs::read(&dest).unwrap(), b"new build");
        assert_ne!(
            inode(&dest),
            running,
            "the running build's file was written over"
        );
        assert_eq!(fs::metadata(&dest).unwrap().mode() & 0o777, 0o755);

        let replaced = inode(&dest);
        write_into_place(&dest, b"archive").unwrap();
        assert_eq!(fs::read(&dest).unwrap(), b"archive");
        assert_ne!(inode(&dest), replaced);
        assert_eq!(names(&out), ["gudo-hostd"]);
    }

    #[test]
    fn a_failed_copy_leaves_the_old_file_and_nothing_else() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("gudo-hostd");
        fs::write(&dest, b"running build").unwrap();
        assert!(copy_into_place(&dir.path().join("missing"), &dest).is_err());
        assert_eq!(fs::read(&dest).unwrap(), b"running build");
        assert_eq!(names(dir.path()), ["gudo-hostd"]);
    }
}
