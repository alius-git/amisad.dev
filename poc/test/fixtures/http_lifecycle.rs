// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
use amisad_common::{json, serve_app, Request, Response, ServiceInfo};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

struct Journal {
    directory: PathBuf,
}

impl Drop for Journal {
    fn drop(&mut self) {
        fs::write(self.directory.join("dropped"), "state dropped\n").unwrap();
    }
}

fn handle(state: &mut Journal, request: &Request) -> Response {
    if request.method == "GET" && request.path == "/journal" {
        let text = fs::read_to_string(state.directory.join("journal")).unwrap_or_default();
        return Response::json(200, &json::s(&text));
    }
    if request.method != "POST" || !matches!(request.path.as_str(), "/append" | "/commit-after-release") {
        return Response::error(404, "not found");
    }
    if request.path == "/commit-after-release" {
        fs::write(state.directory.join("started"), "handler started\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !state.directory.join("release").exists() {
            if Instant::now() >= deadline { return Response::error(503, "release timed out"); }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    let mut journal = OpenOptions::new().create(true).append(true)
        .open(state.directory.join("journal")).unwrap();
    writeln!(journal, "{}", request.body).unwrap();
    journal.sync_all().unwrap();
    Response::json(201, &json::obj(vec![("committed", json::b(true))]))
}

fn main() -> std::io::Result<()> {
    let directory = PathBuf::from(std::env::var_os("JOURNAL_DIRECTORY").unwrap());
    fs::write(directory.join("pid"), std::process::id().to_string())?;
    serve_app(ServiceInfo { name: "lifecycle-fixture", version: "test" }, Journal { directory }, handle)
}
