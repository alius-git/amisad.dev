// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.

// Optional PostgreSQL policy, compiled only by services that own a database.
use amisad_common::Response;
use postgres::{Client, NoTls};

pub fn connect(url: Option<&str>) -> Result<Option<Client>, postgres::Error> {
    match url.filter(|u| !u.is_empty()) {
        None => Ok(None),
        Some(url) => Client::connect(url, NoTls).map(Some),
    }
}

pub fn open(service: &str) -> Option<Client> {
    connect(std::env::var("DATABASE_URL").ok().as_deref()).unwrap_or_else(|e| {
        eprintln!("{service}: DATABASE_URL set but connection failed: {e}");
        std::process::exit(1);
    })
}

// A dead connection cannot recover in this synchronous store; the supervisor
// restarts and reloads it. SQL errors leave the process available for retry.
pub fn store_error(service: &str, db: &Client, what: &str, e: postgres::Error) -> Response {
    if db.is_closed() {
        eprintln!("{service}: {what}: connection lost ({e}); exiting to reload");
        std::process::exit(1);
    }
    Response::error(503, &format!("{what} unavailable: {e}"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn optional_and_invalid_configuration() {
        assert!(super::connect(None).unwrap().is_none());
        assert!(super::connect(Some("")).unwrap().is_none());
        assert!(super::connect(Some("invalid option")).is_err());
    }
}
