// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42dfcad4-028c-4d0b-8cc9-a0a706f24ab8

use crate::{child, Failure, Workspace};
use std::{
    fs::{self, File, OpenOptions, Permissions},
    io::{self, Write},
    net::IpAddr,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

const USERS: [&str; 11] = [
    "maya", "elena", "tom", "priya", "marcel", "kai", "pat", "alex", "sam", "dana", "ingrid",
];
const TOOL: Duration = Duration::from_secs(15);
const ADD_USER: Duration = Duration::from_secs(60);
const DEMO_KEY: &str = "amisad-demo-key";
const DEMO_PUBLIC: &str = "amisad-demo-key.pub";

pub(super) async fn run() -> Result<(), Failure> {
    let uid = login_uid()?;
    let home = login_home(uid).await?;
    let home_directory = owned_directory(&home, uid).map_err(key_error)?;
    println!("== non-admin demo users ({}) ==", USERS.join(", "));
    for user in USERS {
        if !account_exists(user).await? {
            let creation = child(
                "sudo",
                &["-n", "adduser", "--disabled-password", "--gecos", "", user],
                ADD_USER,
            )
            .await;
            match creation {
                Ok(output) => {
                    print!("{}", String::from_utf8_lossy(&output.stdout));
                    eprint!("{}", String::from_utf8_lossy(&output.stderr));
                }
                Err(error) if !account_exists(user).await? => return Err(error),
                Err(_) => (),
            }
        }
    }
    println!("== core->edge demo SSH keypair for the admin (generated here; the private key never leaves this VM) ==");
    reconcile_key(&home, &home_directory, uid).await?;
    println!("amisad vm-core demo users provisioned");
    Ok(())
}

pub(super) async fn prove_edge_login(user: &str, address: &str) -> Result<(), Failure> {
    let invalid = || Failure::new(2, "The edge login needs an account name and IP address");
    if !user.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        || !user
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(invalid());
    }
    let address = address.parse::<IpAddr>().map_err(|_| invalid())?;
    let uid = login_uid()?;
    let home = login_home(uid).await?;
    owned_directory(&home, uid).map_err(key_error)?;
    let ssh = home.join(".ssh");
    owned_directory(&ssh, uid).map_err(key_error)?;
    let key = ssh.join(DEMO_KEY);
    owned_key(&key, uid)
        .map_err(key_error)?
        .ok_or_else(|| Failure::new(1, "The core demo SSH key is unavailable"))?;
    let target = format!("{user}@{address}");
    let output = child(
        "ssh",
        &[
            "-i",
            path_text(&key)?,
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "ConnectTimeout=15",
            "--",
            &target,
            "true",
        ],
        Duration::from_secs(55),
    )
    .await?;
    print!("{}", String::from_utf8_lossy(&output.stdout));
    eprint!("{}", String::from_utf8_lossy(&output.stderr));
    Ok(())
}

pub(super) fn login_uid() -> Result<u32, Failure> {
    // SAFETY: geteuid takes no input and has no side effects.
    let uid = unsafe { libc::geteuid() };
    if uid == 0 {
        Err(Failure::new(
            1,
            "Run core provisioning as the guest administrator",
        ))
    } else {
        Ok(uid)
    }
}

pub(super) async fn login_home(uid: u32) -> Result<PathBuf, Failure> {
    let numeric = uid.to_string();
    let output = child("getent", &["--", "passwd", &numeric], TOOL).await?;
    std::str::from_utf8(&output.stdout)
        .ok()
        .and_then(|value| {
            let value = value.trim_end_matches(['\r', '\n']);
            if value.contains(['\r', '\n']) {
                return None;
            }
            let mut row = value.split(':');
            if row.nth(2)? != numeric {
                return None;
            }
            let path = PathBuf::from(row.nth(2)?);
            path.is_absolute().then_some(path)
        })
        .ok_or_else(|| Failure::new(1, "The guest administrator has no valid home directory"))
}

async fn account_exists(user: &str) -> Result<bool, Failure> {
    match child("id", &["-u", user], TOOL).await {
        Ok(_) => Ok(true),
        Err(error) if error.exit == 1 => Ok(false),
        Err(error) => Err(error),
    }
}

fn key_error(error: io::Error) -> Failure {
    Failure::new(
        1,
        format!("Could not reconcile the core demo SSH key: {error}"),
    )
}

fn wrong_owner() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "The login must own its home, .ssh directory, and demo key files",
    )
}

fn owned_directory(path: &Path, uid: u32) -> io::Result<File> {
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    if directory.metadata()?.uid() == uid {
        Ok(directory)
    } else {
        Err(wrong_owner())
    }
}

fn owned_key(path: &Path, uid: u32) -> io::Result<Option<File>> {
    let key = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(key) => key,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let metadata = key.metadata()?;
    if metadata.is_file() && metadata.uid() == uid && metadata.nlink() == 1 {
        Ok(Some(key))
    } else {
        Err(wrong_owner())
    }
}

async fn public_key(path: &str) -> Result<Vec<u8>, Failure> {
    child("ssh-keygen", &["-y", "-P", "", "-f", path], TOOL)
        .await
        .map(|output| output.stdout)
}

fn path_text(path: &Path) -> Result<&str, Failure> {
    path.to_str()
        .ok_or_else(|| Failure::new(1, "The guest key path must be UTF-8"))
}

async fn reconcile_key(home: &Path, home_directory: &File, uid: u32) -> Result<(), Failure> {
    let ssh = home.join(".ssh");
    match fs::DirBuilder::new().mode(0o700).create(&ssh) {
        Ok(()) => (),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(key_error(error)),
    }
    let directory = owned_directory(&ssh, uid).map_err(key_error)?;
    let _lock = crate::edge_key::DirectoryLock::exclusive(&directory).map_err(key_error)?;
    let key = ssh.join(DEMO_KEY);
    let public = ssh.join(DEMO_PUBLIC);
    let previous = owned_key(&key, uid).map_err(key_error)?;
    owned_key(&public, uid).map_err(key_error)?;
    directory
        .set_permissions(Permissions::from_mode(0o700))
        .map_err(key_error)?;

    let stage = Workspace::create(&ssh, ".amisad-demo").await?;
    let staged_key = stage.0.join(DEMO_KEY);
    let staged_public = stage.0.join(DEMO_PUBLIC);
    let derived = if let Some(previous) = previous {
        previous
            .set_permissions(Permissions::from_mode(0o600))
            .map_err(key_error)?;
        match public_key(path_text(&key)?).await {
            Ok(value) => {
                println!("keeping the existing demo key");
                Some(value)
            }
            Err(error) if error.exit == 1 || error.exit == 255 => None,
            Err(error) => return Err(error),
        }
    } else {
        None
    };
    let generate = derived.is_none();
    let derived = if let Some(derived) = derived {
        derived
    } else {
        let path = path_text(&staged_key)?;
        child(
            "ssh-keygen",
            &[
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "amisad-demo",
                "-f",
                path,
            ],
            TOOL,
        )
        .await?;
        let generated = owned_key(&staged_key, uid)
            .map_err(key_error)?
            .ok_or_else(|| Failure::new(1, "SSH key generation did not create a private key"))?;
        generated
            .set_permissions(Permissions::from_mode(0o600))
            .map_err(key_error)?;
        generated.sync_all().map_err(key_error)?;
        public_key(path).await?
    };

    let mut output = File::create(&staged_public).map_err(key_error)?;
    output.write_all(&derived).map_err(key_error)?;
    output
        .set_permissions(Permissions::from_mode(0o644))
        .map_err(key_error)?;
    output.sync_all().map_err(key_error)?;
    let fingerprint = child("ssh-keygen", &["-lf", path_text(&staged_public)?], TOOL).await?;
    if generate {
        // A retry can always recover the public key from a published private key.
        fs::rename(staged_key, key).map_err(key_error)?;
        directory.sync_all().map_err(key_error)?;
    }
    fs::rename(staged_public, public).map_err(key_error)?;
    directory.sync_all().map_err(key_error)?;
    home_directory.sync_all().map_err(key_error)?;
    println!(
        "demo key fingerprint: {}",
        String::from_utf8_lossy(&fingerprint.stdout).trim_end()
    );
    Ok(())
}
