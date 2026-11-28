// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42fcc57b-a5d7-4c92-b2a6-22c02b47c2f5

use crate::Failure;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader, Read},
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::Path,
    process::{Child, Command, Stdio},
    time::Duration,
};

const TOKEN_LIMIT: usize = 16 * 1024;

fn read_token(input: impl Read) -> io::Result<String> {
    let mut buffer = Vec::new();
    BufReader::new(input.take((TOKEN_LIMIT + 2) as u64)).read_until(b'\n', &mut buffer)?;
    if buffer.last() == Some(&b'\n') {
        buffer.pop();
    }
    if buffer.len() > TOKEN_LIMIT || buffer.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid ledger token on standard input",
        ));
    }
    String::from_utf8(buffer)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Invalid ledger token encoding"))
}

fn open_log(path: &Path, uid: u32) -> io::Result<File> {
    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != uid || metadata.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Expected a private regular slice-runtime log",
        ));
    }
    file.set_len(0)?;
    Ok(file)
}

async fn start(
    executable: &Path,
    log: &Path,
    region: &str,
    ledger: &str,
    resource: &str,
    token: &str,
    settle: Duration,
) -> io::Result<Child> {
    // SAFETY: geteuid takes no arguments and cannot affect memory.
    let uid = unsafe { libc::geteuid() };
    let metadata = fs::symlink_metadata(executable)?;
    if !metadata.is_file() || metadata.uid() != uid || metadata.permissions().mode() & 0o111 == 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Expected the transferred slice-runtime executable",
        ));
    }
    let log = open_log(log, uid)?;
    let mut command = Command::new(executable);
    command
        .env("PORT", "8080")
        .env("REGION", region)
        .env("LEDGER_URL", ledger)
        .env("RESOURCE_URL", resource)
        .env("LEDGER_WRITE_TOKEN", token)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
    // SAFETY: setsid and signal are async-signal-safe. Using independent
    // stdio and ignoring SIGHUP lets the child survive the SSH session.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 || libc::signal(libc::SIGHUP, libc::SIG_IGN) == libc::SIG_ERR {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    tokio::time::sleep(settle).await;
    if let Some(status) = child.try_wait()? {
        return Err(io::Error::other(format!(
            "slice-runtime exited during startup ({status}); see its log"
        )));
    }
    Ok(child)
}

pub(super) async fn run(region: &str, ledger: &str, resource: &str) -> Result<(), Failure> {
    let failure =
        |error: io::Error| Failure::new(1, format!("Could not start slice-runtime: {error}"));
    let token = read_token(io::stdin().lock()).map_err(failure)?;
    start(
        Path::new("/tmp/slice-runtime"),
        Path::new("/tmp/slice-runtime.log"),
        region,
        ledger,
        resource,
        &token,
        Duration::from_secs(1),
    )
    .await
    .map_err(failure)?;
    println!("edge-started");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Workspace, EXECUTABLE_FIXTURES};

    #[test]
    fn reads_only_the_first_token_line_and_limits_invalid_input() {
        assert_eq!(
            read_token(&b"secret\\chunk\nnever-read\n"[..]).unwrap(),
            "secret\\chunk"
        );
        assert_eq!(read_token(&b"\n"[..]).unwrap(), "");
        assert!(read_token(&b"token\0here\n"[..]).is_err());
        assert!(read_token(vec![b'x'; TOKEN_LIMIT + 1].as_slice()).is_err());
    }

    #[tokio::test]
    async fn starts_a_detached_process_with_token_and_typed_environment() {
        let _fixture = EXECUTABLE_FIXTURES.lock().await;
        let root = Workspace::create(&std::env::temp_dir(), "amisad-slice-start-test")
            .await
            .unwrap();
        let executable = root.0.join("slice-runtime");
        let log = root.0.join("runtime.log");
        fs::write(&executable, concat!(
            "#!/bin/sh\nset -eu\n",
            "[ \"$PORT\" = 8080 ] && [ \"$REGION\" = 'test region' ] && ",
            "[ \"$LEDGER_URL\" = 'http://ledger/path?a=b&c=d' ] && [ \"$RESOURCE_URL\" = 'http://resource' ] && ",
            "[ \"$LEDGER_WRITE_TOKEN\" = 'token\\literal' ] || exit 91\n",
            "echo started\nexec sleep 0.5\n",
        )).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        let mut child = start(
            &executable,
            &log,
            "test region",
            "http://ledger/path?a=b&c=d",
            "http://resource",
            "token\\literal",
            Duration::from_millis(100),
        )
        .await
        .unwrap();
        let pid = child.id() as i32;
        // SAFETY: getsid reads process metadata for the child that was just started.
        let session = unsafe { libc::getsid(pid) };
        assert_eq!(session, pid);
        assert!(child.wait().unwrap().success());
        assert_eq!(fs::read_to_string(&log).unwrap(), "started\n");
        assert_eq!(
            fs::metadata(&log).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[tokio::test]
    async fn reports_early_exit_and_refuses_to_overwrite_a_linked_log() {
        let _fixture = EXECUTABLE_FIXTURES.lock().await;
        let root = Workspace::create(&std::env::temp_dir(), "amisad-slice-start-test")
            .await
            .unwrap();
        let executable = root.0.join("slice-runtime");
        let log = root.0.join("runtime.log");
        fs::write(&executable, "#!/bin/sh\necho fixture\nexit 19\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        let error = start(
            &executable,
            &log,
            "",
            "",
            "",
            "",
            Duration::from_millis(100),
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("19"));
        assert_eq!(fs::read_to_string(&log).unwrap(), "fixture\n");

        fs::remove_file(&log).unwrap();
        let other = root.0.join("other");
        fs::write(&other, "preserve this").unwrap();
        std::os::unix::fs::symlink(&other, &log).unwrap();
        assert!(start(
            &executable,
            &log,
            "",
            "",
            "",
            "",
            Duration::from_millis(100)
        )
        .await
        .is_err());
        assert_eq!(fs::read_to_string(&other).unwrap(), "preserve this");
    }
}
