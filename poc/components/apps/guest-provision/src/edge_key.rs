// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42a7a1a1-b7ae-42cf-bf8a-68d5ac60e2fa

use crate::Failure;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use std::{
    ffi::{CStr, CString},
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

const KEY_LIMIT: u64 = 256;
const FILE_LIMIT: u64 = 8 * 1024 * 1024;
const PREFIX: &[u8] = b"\0\0\0\x0bssh-ed25519\0\0\0\x20";
const KEYS: &CStr = c"authorized_keys";

pub fn run() -> Result<(), Failure> {
    let invalid = || {
        Failure::new(
            2,
            "A single canonical AmisAd Ed25519 public key is required.",
        )
    };
    let mut wire = Vec::new();
    io::stdin()
        .lock()
        .take(KEY_LIMIT + 1)
        .read_to_end(&mut wire)
        .map_err(|_| invalid())?;
    let key = parse(&wire).ok_or_else(invalid)?;
    let home = std::env::var_os("HOME")
        .ok_or_else(|| Failure::new(2, "The edge login has no home directory."))?;
    rewrite(Path::new(&home), &key)
        .map_err(|error| Failure::new(1, format!("Could not authorize the edge demo key: {error}")))
}

fn parse(wire: &[u8]) -> Option<String> {
    if wire.len() as u64 > KEY_LIMIT {
        return None;
    }
    let mut fields = std::str::from_utf8(wire).ok()?.trim().split(' ');
    let (Some("ssh-ed25519"), Some(key), Some("amisad-demo"), None) =
        (fields.next(), fields.next(), fields.next(), fields.next())
    else {
        return None;
    };
    let decoded = STANDARD.decode(key).ok()?;
    if !decoded.starts_with(PREFIX)
        || decoded.len() != PREFIX.len() + 32
        || STANDARD.encode(decoded) != key
    {
        return None;
    }
    Some(format!("ssh-ed25519 {key} amisad-demo"))
}

fn open_at(dir: &File, leaf: &CStr, flags: libc::c_int, mode: libc::mode_t) -> io::Result<File> {
    // SAFETY: the descriptor and C string remain live during openat.
    let descriptor = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            leaf.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: success returned a new owned descriptor.
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

fn owner_invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "The login must own its home, .ssh directory, and authorized_keys file",
    )
}

pub(super) struct DirectoryLock<'a>(&'a File);

impl<'a> DirectoryLock<'a> {
    pub(super) fn exclusive(directory: &'a File) -> io::Result<Self> {
        // SAFETY: the lock is held by the open directory.
        if unsafe { libc::flock(directory.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(directory))
    }
}

impl Drop for DirectoryLock<'_> {
    fn drop(&mut self) {
        // Explicit release also unlocks a descriptor inherited by a child
        // between fork and close-on-exec.
        // SAFETY: the borrowed directory remains open through this call.
        let _ = unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn rewrite(home: &Path, key: &str) -> io::Result<()> {
    if !home.is_absolute() {
        return Err(owner_invalid());
    }
    // SAFETY: geteuid has no input or side effects.
    let uid = unsafe { libc::geteuid() };
    let home = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(home)?;
    if home.metadata()?.uid() != uid {
        return Err(owner_invalid());
    }
    // SAFETY: the home descriptor and constant leaf are valid for the call.
    if unsafe { libc::mkdirat(home.as_raw_fd(), c".ssh".as_ptr(), 0o700) } != 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    let directory = open_at(&home, c".ssh", libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
    if directory.metadata()?.uid() != uid {
        return Err(owner_invalid());
    }
    let _lock = DirectoryLock::exclusive(&directory)?;
    let mut before = Vec::new();
    match open_at(&directory, KEYS, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
        Ok(file) => {
            let meta = file.metadata()?;
            if !meta.is_file() || meta.uid() != uid {
                return Err(owner_invalid());
            }
            file.take(FILE_LIMIT + 1).read_to_end(&mut before)?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error),
    }
    if before.len() as u64 > FILE_LIMIT {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "The authorized_keys file is too large",
        ));
    }
    directory.set_permissions(std::fs::Permissions::from_mode(0o700))?;

    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let pending = CString::new(format!(".authorized_keys-{}-{unique}", std::process::id()))
        .map_err(io::Error::other)?;
    let file = open_at(
        &directory,
        &pending,
        libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
        0o600,
    )?;
    let result = publish(&directory, &pending, file, &before, key);
    if result.is_err() {
        // SAFETY: removal is restricted to this invocation's staging leaf.
        let _ = unsafe { libc::unlinkat(directory.as_raw_fd(), pending.as_ptr(), 0) };
    }
    result?;
    // A replay may be publishing the first key into a directory created by
    // an interrupted invocation. Make that home entry durable as well.
    home.sync_all()
}

fn publish(
    directory: &File,
    pending: &CStr,
    mut file: File,
    before: &[u8],
    key: &str,
) -> io::Result<()> {
    for line in before.split_inclusive(|byte| *byte == b'\n') {
        let last = line
            .rsplit(|byte| byte.is_ascii_whitespace())
            .find(|field| !field.is_empty());
        if last == Some(b"amisad-demo") {
            continue;
        }
        file.write_all(line)?;
        if !line.ends_with(b"\n") {
            file.write_all(b"\n")?;
        }
    }
    writeln!(file, "{key}")?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    file.sync_all()?;
    // SAFETY: both leaves are in the same open, checked .ssh directory.
    let dir = directory.as_raw_fd();
    if unsafe { libc::renameat(dir, pending.as_ptr(), dir, KEYS.as_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    directory.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::symlink, path::PathBuf};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let id = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path =
                std::env::temp_dir().join(format!("amisad-edge-key-{}-{id}", std::process::id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn key(seed: u8) -> String {
        let mut raw = PREFIX.to_vec();
        raw.extend_from_slice(&[seed; 32]);
        format!("ssh-ed25519 {} amisad-demo", STANDARD.encode(raw))
    }

    #[test]
    fn accepts_only_one_canonical_ed25519_public_key() {
        let public = key(7);
        assert_eq!(
            parse(format!("{public}\n").as_bytes()),
            Some(public.clone())
        );
        assert!(parse(format!("{public}\n{public}\n").as_bytes()).is_none());
        assert!(parse(format!("command=\"false\" {public}").as_bytes()).is_none());
        assert!(parse(b"-----BEGIN OPENSSH PRIVATE KEY-----\n").is_none());
        assert!(parse(b"ssh-ed25519 aaaa amisad-demo\n").is_none());
    }

    #[test]
    fn rotates_once_and_keeps_other_key_bytes_and_private_modes() {
        let home = Fixture::new();
        let path = home.0.join(".ssh/authorized_keys");
        let original = key(1);
        rewrite(&home.0, &original).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), format!("{original}\n"));
        let mut other = format!("{original}\nssh-ed25519 example existing-").into_bytes();
        other.push(0xff);
        fs::write(&path, &other).unwrap();
        let replacement = key(2);
        rewrite(&home.0, &replacement).unwrap();
        rewrite(&home.0, &replacement).unwrap();
        let mut expected = b"ssh-ed25519 example existing-\xff\n".to_vec();
        expected.extend_from_slice(format!("{replacement}\n").as_bytes());
        assert_eq!(fs::read(&path).unwrap(), expected);
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let ssh = home.0.join(".ssh");
        assert_eq!(
            fs::metadata(&ssh).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(fs::read_dir(ssh).unwrap().count(), 1);
    }

    #[test]
    fn refuses_links_without_touching_their_destination() {
        let home = Fixture::new();
        let target = Fixture::new();
        let directory = home.0.join(".ssh");
        let outside = target.0.join("authorized_keys");
        fs::write(&outside, b"outside").unwrap();
        symlink(&target.0, &directory).unwrap();
        assert!(rewrite(&home.0, &key(1)).is_err());
        fs::remove_file(&directory).unwrap();
        fs::create_dir(&directory).unwrap();
        symlink(&outside, directory.join("authorized_keys")).unwrap();
        assert!(rewrite(&home.0, &key(1)).is_err());
        assert_eq!(fs::read(outside).unwrap(), b"outside");
    }
}
