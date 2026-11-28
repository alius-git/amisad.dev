// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4234b72d-a8db-4663-a199-fc91787c51ce

use super::SERVICES;
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::{ffi::OsStrExt, fs::PermissionsExt};
use std::path::Path;

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn revision(path: &Path) -> io::Result<String> {
    let metadata = path.symlink_metadata()?;
    if !metadata.is_file() || !matches!(metadata.len(), 40 | 41) {
        return Err(invalid("Expected a regular 40-character source revision"));
    }
    let content = fs::read_to_string(path)?;
    let value = content.strip_suffix('\n').unwrap_or(&content);
    if value.len() != 40
        || !value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    {
        return Err(invalid("Invalid source revision"));
    }
    Ok(value.to_owned())
}

fn verify_executable(path: &Path, machine: u16) -> io::Result<()> {
    let metadata = path.symlink_metadata()?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(invalid(format!(
            "Expected an executable regular file: {}",
            path.display()
        )));
    }
    let mut header = [0; 20];
    File::open(path)?.read_exact(&mut header)?;
    if &header[..6] != b"\x7fELF\x02\x01" || u16::from_le_bytes([header[18], header[19]]) != machine
    {
        return Err(invalid(format!(
            "Artifact is for a different architecture: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn activate(project: &Path, candidate: &Path, destination: &Path) -> io::Result<()> {
    activate_from_source(project, candidate, destination, true)
}

pub(super) fn binaries() -> impl Iterator<Item = &'static str> {
    SERVICES
        .into_iter()
        .chain(["slice-runtime", "buyer-client", "amisad-provision"])
}

pub(super) fn activate_stash(
    project: &Path,
    candidate: &Path,
    destination: &Path,
) -> io::Result<()> {
    activate_from_source(project, candidate, destination, false)
}

fn activate_from_source(
    project: &Path,
    candidate: &Path,
    destination: &Path,
    signed: bool,
) -> io::Result<()> {
    let machine = match std::env::consts::ARCH {
        "x86_64" => 0x3e,
        "aarch64" => 0xb7,
        _ => return Err(invalid("Unsupported guest architecture")),
    };
    for directory in [
        project.to_path_buf(),
        candidate.to_path_buf(),
        project.join("poc"),
    ] {
        if !directory.symlink_metadata()?.is_dir() {
            return Err(invalid(format!(
                "Expected a real directory: {}",
                directory.display()
            )));
        }
    }
    if signed
        && revision(&project.join(".yuruna-revision"))?
            != revision(&candidate.join("framework-revision"))?
    {
        return Err(invalid(
            "Signed runtime revision differs from the project archive",
        ));
    }
    let target = project.join("poc/target");
    fs::create_dir(&target)?;
    let release = target.join("release");
    fs::create_dir(&release)?;
    for binary in binaries() {
        let source = candidate.join(binary);
        verify_executable(&source, machine)?;
        fs::copy(source, release.join(binary))?;
    }

    match destination.symlink_metadata() {
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::rename(project, destination),
        Ok(entry) if entry.is_dir() => {
            let source = CString::new(project.as_os_str().as_bytes())?;
            let destination = CString::new(destination.as_os_str().as_bytes())?;
            // Exchange whole trees so a reader always sees one complete revision.
            let status = unsafe {
                libc::renameat2(
                    libc::AT_FDCWD,
                    source.as_ptr(),
                    libc::AT_FDCWD,
                    destination.as_ptr(),
                    libc::RENAME_EXCHANGE,
                )
            };
            if status == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        }
        Ok(_) => Err(invalid("The active project must be a real directory")),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Workspace;

    fn fixture(root: &Path) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        let project = root.join("project");
        let candidate = root.join("candidate");
        let destination = root.join("live");
        fs::create_dir_all(project.join("poc")).unwrap();
        fs::create_dir(&candidate).unwrap();
        fs::write(project.join(".yuruna-revision"), "a".repeat(40)).unwrap();
        fs::write(
            candidate.join("framework-revision"),
            format!("{}\n", "a".repeat(40)),
        )
        .unwrap();
        let machine: u16 = if cfg!(target_arch = "aarch64") {
            0xb7
        } else {
            0x3e
        };
        let mut header = [0; 20];
        header[..6].copy_from_slice(b"\x7fELF\x02\x01");
        header[18..].copy_from_slice(&machine.to_le_bytes());
        for name in
            SERVICES
                .into_iter()
                .chain(["slice-runtime", "buyer-client", "amisad-provision"])
        {
            let path = candidate.join(name);
            fs::write(&path, header).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        (project, candidate, destination)
    }

    #[tokio::test]
    async fn activates_a_complete_tree_on_first_install_and_replaces_it_atomically() {
        let scratch = Workspace::create(&std::env::temp_dir(), "amisad-runtime-test")
            .await
            .unwrap();
        let (project, candidate, live) = fixture(&scratch.0);
        activate(&project, &candidate, &live).unwrap();
        assert!(!project.exists());
        assert_eq!(
            fs::read_dir(live.join("poc/target/release"))
                .unwrap()
                .count(),
            13
        );

        fs::remove_dir_all(candidate).unwrap();
        fs::write(live.join("previous-marker"), b"keep through swap").unwrap();
        let (project, candidate, live) = fixture(&scratch.0);
        activate(&project, &candidate, &live).unwrap();
        assert!(!live.join("previous-marker").exists());
        assert!(live.join("poc/target/release/amisad-provision").is_file());
        assert_eq!(
            fs::read(project.join("previous-marker")).unwrap(),
            b"keep through swap"
        );
    }

    #[tokio::test]
    async fn leaves_the_previous_tree_untouched_when_any_runtime_check_fails() {
        for problem in ["revision", "missing", "architecture", "symlink"] {
            let scratch = Workspace::create(&std::env::temp_dir(), "amisad-runtime-test")
                .await
                .unwrap();
            let (project, candidate, live) = fixture(&scratch.0);
            fs::create_dir(&live).unwrap();
            fs::write(live.join("active"), b"previous").unwrap();
            let executable = candidate.join("amisad-provision");
            match problem {
                "revision" => fs::write(project.join(".yuruna-revision"), "b".repeat(40)).unwrap(),
                "missing" => fs::remove_file(&executable).unwrap(),
                "architecture" => fs::write(&executable, [0; 20]).unwrap(),
                "symlink" => {
                    fs::remove_file(&executable).unwrap();
                    std::os::unix::fs::symlink(candidate.join("buyer-client"), &executable)
                        .unwrap();
                }
                _ => unreachable!(),
            }
            assert!(activate(&project, &candidate, &live).is_err(), "{problem}");
            assert_eq!(fs::read(live.join("active")).unwrap(), b"previous");
            assert_eq!(fs::read_dir(&live).unwrap().count(), 1);
        }
    }
}
