//! Minimal AppLoad lifecycle client; calendar data continues over HTTP.
use std::{
    io, mem,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    thread,
    time::Duration,
};
pub fn connect(path: &str) -> io::Result<OwnedFd> {
    if path.len() >= 108 || path.as_bytes().contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid AppLoad socket path",
        ));
    }
    // SAFETY: valid AF_UNIX socket; OwnedFd closes it on all error paths.
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let mut addr: libc::sockaddr_un = unsafe { mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as _;
    for (a, b) in addr.sun_path.iter_mut().zip(path.bytes()) {
        *a = b as _;
    }
    let mut connected = false;
    for _ in 0..50 {
        if unsafe {
            libc::connect(
                fd.as_raw_fd(),
                &addr as *const _ as *const libc::sockaddr,
                mem::size_of_val(&addr) as _,
            )
        } == 0
        {
            connected = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    if !connected {
        return Err(io::Error::last_os_error());
    }
    // Dedicated reader follows native-endian u32 type/length headers in separate SEQPACKET records.
    let reader = fd.try_clone()?;
    thread::spawn(move || {
        let read = || -> io::Result<()> {
            loop {
                let mut header = [0u8; 8];
                let n = unsafe {
                    libc::recv(
                        reader.as_raw_fd(),
                        header.as_mut_ptr() as _,
                        8,
                        libc::MSG_TRUNC,
                    )
                };
                if n == 0 {
                    return Ok(());
                }
                if n != 8 {
                    return Err(io::Error::other("invalid AppLoad header"));
                }
                let kind = u32::from_ne_bytes(header[..4].try_into().unwrap());
                let len = u32::from_ne_bytes(header[4..].try_into().unwrap()) as usize;
                if len > 10 * 1024 * 1024 {
                    return Err(io::Error::other("oversized AppLoad packet"));
                }
                if len > 0 {
                    let mut payload = vec![0u8; len];
                    let n = unsafe {
                        libc::recv(
                            reader.as_raw_fd(),
                            payload.as_mut_ptr() as _,
                            len,
                            libc::MSG_TRUNC,
                        )
                    };
                    if n != len as isize {
                        return Err(io::Error::other("invalid AppLoad payload"));
                    }
                }
                if kind == u32::MAX {
                    return Ok(());
                }
            }
        };
        if let Err(e) = read() {
            eprintln!("AppLoad lifecycle: {e}");
        }
        // No child processes: closing lifecycle connection releases HTTP listener and SQLite.
        std::process::exit(0);
    });
    Ok(fd)
}
