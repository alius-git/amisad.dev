// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42aaecfa-1f79-4ea5-9114-3a94cf6897fe

use crate::Failure;
use std::{
    fs,
    io::{self, ErrorKind},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::MetadataExt,
    },
    path::Path,
    time::Duration,
};
use tokio::time::{sleep, Instant};

pub async fn run() -> Result<(), Failure> {
    stop(
        "slice-runtime",
        Duration::from_secs(10),
        Duration::from_secs(5),
    )
    .await
    .map_err(|error| Failure::new(1, error.to_string()))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Identity {
    start: u64,
    uid: u32,
}

struct Process {
    pid: i32,
    handle: OwnedFd,
    identity: Identity,
}

fn start_time(stat: &str, name: &str) -> Option<u64> {
    let (_, data) = stat.split_once(" (")?;
    let (comm, fields) = data.rsplit_once(") ")?;
    if comm != name || fields.starts_with("Z ") || fields.starts_with("X ") {
        return None;
    }
    fields.split_ascii_whitespace().nth(19)?.parse().ok()
}

fn identity(stat: &Path, name: &str) -> io::Result<Option<Identity>> {
    let content = match fs::read_to_string(stat) {
        Ok(content) => content,
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::NotFound | ErrorKind::PermissionDenied | ErrorKind::InvalidData
            ) =>
        {
            return Ok(None)
        }
        Err(error) => return Err(error),
    };
    let Some(start) = start_time(&content, name) else {
        return Ok(None);
    };
    match fs::metadata(stat) {
        Ok(entry) => Ok(Some(Identity {
            start,
            uid: entry.uid(),
        })),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn find(name: &str) -> io::Result<Vec<Process>> {
    let mut current = Vec::new();
    // SAFETY: geteuid takes no arguments and cannot affect memory.
    let uid = unsafe { libc::geteuid() };
    for entry in fs::read_dir("/proc")? {
        let entry = entry?;
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<i32>().ok())
        else {
            continue;
        };
        let stat = entry.path().join("stat");
        let Some(before) = identity(&stat, name)? else {
            continue;
        };
        if uid != 0 && before.uid != uid {
            return Err(io::Error::new(
                ErrorKind::PermissionDenied,
                format!("{name} (pid {pid}) belongs to another user"),
            ));
        }
        // SAFETY: pidfd_open accepts a PID and a zero flag word. On success
        // it returns a new descriptor owned by this process.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) } as i32;
        if raw < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                continue;
            }
            return Err(error);
        }
        // SAFETY: the successful pidfd_open above produced this descriptor.
        let handle = unsafe { OwnedFd::from_raw_fd(raw) };
        if identity(&stat, name)? == Some(before) {
            current.push(Process {
                pid,
                handle,
                identity: before,
            });
        }
    }
    current.sort_unstable_by_key(|process| process.pid);
    Ok(current)
}

impl Process {
    fn signal(&self, name: &str, signal: i32) -> io::Result<()> {
        if self.exited()? {
            return Ok(());
        }
        let stat = format!("/proc/{}/stat", self.pid);
        if identity(Path::new(&stat), name)? != Some(self.identity) {
            if self.exited()? {
                return Ok(());
            }
            return Err(io::Error::other(format!(
                "{name} (pid {}) changed identity before signaling",
                self.pid
            )));
        }

        // SAFETY: handle owns a live descriptor and zero flags permit a null
        // siginfo pointer. The kernel binds this signal to that exact PID.
        let result = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                self.handle.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        if result == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(error)
        }
    }

    fn exited(&self) -> io::Result<bool> {
        let mut poll = libc::pollfd {
            fd: self.handle.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll is a valid, writable one-element array for the call.
        let result = unsafe { libc::poll(&mut poll, 1, 0) };
        if result < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == ErrorKind::Interrupted {
                Ok(false)
            } else {
                Err(error)
            };
        }
        if poll.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
            return Err(io::Error::other(
                "could not read slice-runtime process status",
            ));
        }
        Ok(poll.revents & (libc::POLLIN | libc::POLLHUP) != 0)
    }
}

async fn wait_for_exit(processes: &[Process], budget: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + budget;
    loop {
        let mut all = true;
        for process in processes {
            if !process.exited()? {
                all = false;
            }
        }
        if all {
            return Ok(true);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(false);
        }
        sleep(remaining.min(Duration::from_millis(100))).await;
    }
}

async fn stop(name: &str, grace: Duration, kill: Duration) -> io::Result<()> {
    let processes = find(name)?;
    if processes.is_empty() {
        return Ok(());
    }
    let pids = processes
        .iter()
        .map(|process| process.pid.to_string())
        .collect::<Vec<_>>()
        .join(", ");
    for process in &processes {
        process.signal(name, libc::SIGTERM)?;
    }
    let escalated = !wait_for_exit(&processes, grace).await?;
    if escalated {
        for process in &processes {
            if !process.exited()? {
                process.signal(name, libc::SIGKILL)?;
            }
        }
        if !wait_for_exit(&processes, kill).await? {
            return Err(io::Error::other(format!(
                "{name} (pid {pids}) survived SIGTERM and SIGKILL"
            )));
        }
    }
    // A concurrently started instance could still hold the binary. Keep the
    // caller from copying over it without signaling a process it did not select.
    if !find(name)?.is_empty() {
        return Err(io::Error::other(format!(
            "another {name} instance started while stopping pid {pids}"
        )));
    }
    if escalated {
        println!("stopped {name} (pid {pids}, SIGKILL after SIGTERM was outlived)");
    } else {
        println!("stopped {name} (pid {pids})");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Workspace;

    #[test]
    fn process_status_requires_the_exact_live_comm_and_start_ticks() {
        let stat = "123 (slice-runtime) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 902 0";
        assert_eq!(start_time(stat, "slice-runtime"), Some(902));
        assert_eq!(start_time(stat, "slice"), None);
        assert_eq!(
            start_time(&stat.replace(") S ", ") Z "), "slice-runtime"),
            None
        );
    }

    #[tokio::test]
    async fn stops_a_disposable_process_and_waits_until_the_executable_is_writable() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let stage = Workspace::create(&std::env::temp_dir(), "amisad-slice-test")
            .await
            .unwrap();
        let name = format!("yrnsl{}", std::process::id());
        let path = stage.0.join(&name);
        fs::copy("/bin/sleep", &path).unwrap();
        let mut child = tokio::process::Command::new(&path)
            .arg("300")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = child.id().unwrap() as i32;
        let state = std::path::PathBuf::from(format!("/proc/{pid}/stat"));
        let limit = Instant::now() + Duration::from_secs(2);
        while identity(&state, &name).unwrap().is_none() {
            assert!(Instant::now() < limit);
            sleep(Duration::from_millis(5)).await;
        }
        assert!(fs::OpenOptions::new().append(true).open(&path).is_err());
        let mut observation = find(&name).unwrap().pop().unwrap();
        observation.identity.start = observation.identity.start.saturating_add(1);
        assert!(observation.signal(&name, libc::SIGTERM).is_err());
        assert!(child.try_wait().unwrap().is_none());
        stop(&name, Duration::from_secs(2), Duration::from_secs(2))
            .await
            .unwrap();
        assert!(!child.wait().await.unwrap().success());
        assert!(fs::OpenOptions::new().append(true).open(path).is_ok());
    }
}
