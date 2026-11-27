// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 421ef39a-170f-4ea6-936b-09146659e9fb

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::time::Duration;
use tokio::sync::{mpsc, watch, Mutex};

const MESSAGE_LIMIT: usize = 64 * 1024;
const HOST_TIMEOUT: Duration = Duration::from_secs(8);

pub struct Bridge {
    connection: Mutex<Connection>,
}

struct Connection {
    next_id: u64,
    responses: mpsc::Receiver<(u64, Value)>,
}

impl Bridge {
    pub fn open() -> (Self, watch::Receiver<bool>) {
        let (stopped, stop) = watch::channel(false);
        let (sender, responses) = mpsc::channel(8);
        // Only the launcher owns the pipe writer. EOF is also a stop signal
        // so an interrupted console cannot leave a detached listener running.
        std::thread::spawn(move || {
            let stdin = io::stdin();
            let mut input = stdin.lock();
            let mut line = Vec::new();
            loop {
                line.clear();
                let result = {
                    use std::io::Read;
                    (&mut input)
                        .take(MESSAGE_LIMIT as u64)
                        .read_until(b'\n', &mut line)
                };
                if !matches!(result, Ok(n) if n > 0) || !line.ends_with(b"\n") {
                    break;
                }
                let Ok(message) = serde_json::from_slice::<Value>(&line) else {
                    break;
                };
                match message["kind"].as_str() {
                    Some("stop") => break,
                    Some("response") => {
                        if let (Some(id), Some(value)) =
                            (message["id"].as_u64(), message.get("value"))
                        {
                            if sender.try_send((id, value.clone())).is_err() {
                                break;
                            }
                        } else {
                            break;
                        }
                    }
                    _ => break,
                }
            }
            let _ = stopped.send(true);
        });
        (
            Self {
                connection: Mutex::new(Connection {
                    next_id: 0,
                    responses,
                }),
            },
            stop,
        )
    }

    pub async fn request(&self, resource: &str) -> Option<Value> {
        tokio::time::timeout(HOST_TIMEOUT, async {
            let mut connection = self.connection.lock().await;
            connection.next_id = connection.next_id.checked_add(1)?;
            let id = connection.next_id;
            // Never print the response or expose the inherited pipe to HTTP.
            let request = json!({"id":id,"resource":resource});
            {
                let mut stdout = io::stdout().lock();
                writeln!(stdout, "AMISAD-HOST {request}").ok()?;
                stdout.flush().ok()?;
            }
            while let Some((response_id, response)) = connection.responses.recv().await {
                if response_id == id {
                    return Some(response);
                }
            }
            None
        })
        .await
        .unwrap_or(None)
    }
}
