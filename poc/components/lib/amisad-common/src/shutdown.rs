// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
use std::io::{self, ErrorKind};
use std::net::TcpListener;
use std::os::fd::AsRawFd;
use std::os::raw::{c_int, c_short};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

static REQUESTED: AtomicBool = AtomicBool::new(false);
static INSTALLED: OnceLock<Result<(), i32>> = OnceLock::new();
const SIGTERM: c_int = 15;
const POLLIN: c_short = 0x0001;
const POLLERR: c_short = 0x0008;
const POLLHUP: c_short = 0x0010;
const POLLNVAL: c_short = 0x0020;

// poll's nfds_t is unsigned long on Linux and unsigned int on Darwin/BSD.
#[cfg(target_os = "linux")]
type DescriptorCount = std::os::raw::c_ulong;
#[cfg(any(target_vendor = "apple", target_os = "freebsd", target_os = "openbsd",
          target_os = "netbsd", target_os = "dragonfly", target_os = "android"))]
type DescriptorCount = std::os::raw::c_uint;
#[cfg(not(any(target_os = "linux", target_vendor = "apple", target_os = "freebsd",
              target_os = "openbsd", target_os = "netbsd", target_os = "dragonfly", target_os = "android")))]
compile_error!("graceful shutdown needs verified POSIX signal/poll bindings for this Unix target");

#[repr(C)]
struct PollDescriptor {
    fd: c_int,
    events: c_short,
    revents: c_short,
}

extern "C" {
    fn signal(number: c_int, handler: usize) -> usize;
    fn poll(descriptors: *mut PollDescriptor, count: DescriptorCount, timeout: c_int) -> c_int;
}

extern "C" fn request_shutdown(_: c_int) {
    // The handler cannot allocate, lock, or perform I/O. The atomic flag is
    // process-wide and never reset, so repeated signals cannot reopen intake.
    REQUESTED.store(true, Ordering::Relaxed);
}

pub fn install() -> io::Result<()> {
    let result = INSTALLED.get_or_init(|| {
        // POSIX SIGTERM is 15 on the supported Linux/BSD service targets.
        // Keeping the handler installed for the process lifetime avoids races
        // between an arriving signal and cleanup of per-server state.
        if unsafe { signal(SIGTERM, request_shutdown as *const () as usize) } == usize::MAX {
            Err(io::Error::last_os_error().raw_os_error().unwrap_or(22))
        } else {
            Ok(())
        }
    });
    result.map_err(io::Error::from_raw_os_error)
}

pub fn requested() -> bool {
    REQUESTED.load(Ordering::Relaxed)
}

pub fn transient_accept_error(error: &io::Error) -> bool {
    if matches!(error.kind(), ErrorKind::ConnectionAborted | ErrorKind::ConnectionReset
                | ErrorKind::HostUnreachable | ErrorKind::NetworkUnreachable) {
        return true;
    }
    // Linux forwards pending connection errors through accept, rather than
    // through the accepted socket. These errno values are the AMD64/ARM64
    // ABI; other Linux architectures can assign different numbers.
    #[cfg(all(any(target_os = "linux", target_os = "android"),
              any(target_arch = "x86_64", target_arch = "aarch64")))]
    if matches!(error.raw_os_error(), Some(100 | 71 | 92 | 112 | 64 | 113 | 95 | 101)) {
        return true;
    }
    false
}

pub fn wait_for_connection(listener: &TcpListener) -> io::Result<()> {
    let mut descriptor = PollDescriptor { fd: listener.as_raw_fd(), events: POLLIN, revents: 0 };
    // A readiness wait returns immediately for new work; sleeping after a
    // nonblocking accept would add its whole cadence to ordinary requests.
    // The timeout also bounds shutdown if a signal reaches another thread.
    if unsafe { poll(&mut descriptor, 1, 500) } < 0 {
        let error = io::Error::last_os_error();
        if error.kind() != ErrorKind::Interrupted { return Err(error); }
    } else if descriptor.revents & (POLLERR | POLLHUP | POLLNVAL) != 0 {
        // Invalid, hung-up, or failed listeners must not become a busy loop.
        return Err(io::Error::new(ErrorKind::Other, "HTTP listener readiness failed"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_connection_keeps_listener_available_but_resource_errors_do_not_spin() {
        for kind in [ErrorKind::ConnectionAborted, ErrorKind::ConnectionReset,
                     ErrorKind::HostUnreachable, ErrorKind::NetworkUnreachable] {
            assert!(transient_accept_error(&io::Error::from(kind)), "{kind:?}");
        }
        for kind in [ErrorKind::PermissionDenied, ErrorKind::InvalidInput, ErrorKind::OutOfMemory] {
            assert!(!transient_accept_error(&io::Error::from(kind)), "{kind:?}");
        }
    }

    #[test]
    #[cfg(all(any(target_os = "linux", target_os = "android"),
              any(target_arch = "x86_64", target_arch = "aarch64")))]
    fn pending_linux_network_failures_are_retried_but_invalid_listener_is_fatal() {
        for (name, number) in [("ENETDOWN", 100), ("EPROTO", 71), ("ENOPROTOOPT", 92),
                               ("EHOSTDOWN", 112), ("ENONET", 64), ("EHOSTUNREACH", 113),
                               ("EOPNOTSUPP", 95), ("ENETUNREACH", 101)] {
            assert!(transient_accept_error(&io::Error::from_raw_os_error(number)), "{name}");
        }
        for (name, number) in [("EBADF", 9), ("EINVAL", 22), ("ENFILE", 23), ("EMFILE", 24)] {
            assert!(!transient_accept_error(&io::Error::from_raw_os_error(number)), "{name}");
        }
    }
}
