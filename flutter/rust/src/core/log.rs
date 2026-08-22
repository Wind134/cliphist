use parking_lot::Mutex;
use std::fs::File;
use std::io::Write;
use std::sync::OnceLock;

use crate::core::storage;

const MAX_LOG_SIZE: u64 = 5 * 1024 * 1024;
const MAX_LOG_MESSAGE_BYTES: usize = 4096;

pub fn get_log_path() -> std::path::PathBuf {
    storage::app_data_dir().join("cliphist.log")
}

/// A single append handle reused for the whole process lifetime, instead of
/// open→write→flush→close on every log line. Guarded by a mutex so it's safe
/// to call from any thread. Opened lazily on first use.
struct LogWriter {
    file: Option<File>,
    bytes_written: u64,
}

static LOG_FILE: OnceLock<Mutex<LogWriter>> = OnceLock::new();

fn handle() -> &'static Mutex<LogWriter> {
    LOG_FILE.get_or_init(|| {
        let path = get_log_path();
        let bytes_written = std::fs::metadata(&path).map_or(0, |metadata| metadata.len());
        Mutex::new(LogWriter {
            file: storage::open_private_append(&path).ok(),
            bytes_written,
        })
    })
}

pub fn write_log(msg: &str) {
    let ts = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
    let message = truncate_char_boundary(msg, MAX_LOG_MESSAGE_BYTES);
    let line = format!("[{ts}] {message}\n");
    let mut guard = handle().lock();

    if guard.bytes_written.saturating_add(line.len() as u64) > MAX_LOG_SIZE {
        rotate(&mut guard);
    }
    if guard.file.is_none() {
        guard.file = storage::open_private_append(&get_log_path()).ok();
        guard.bytes_written = std::fs::metadata(get_log_path()).map_or(0, |meta| meta.len());
    }
    let wrote = guard
        .file
        .as_mut()
        .is_some_and(|file| file.write_all(line.as_bytes()).is_ok() && file.flush().is_ok());
    if wrote {
        guard.bytes_written = guard.bytes_written.saturating_add(line.len() as u64);
    } else {
        guard.file = None;
    }
}

fn rotate(writer: &mut LogWriter) {
    if let Some(file) = writer.file.take() {
        let _ = file.sync_all();
    }
    let path = get_log_path();
    let rotated = path.with_extension("log.1");
    let backup_written = std::fs::read(&path)
        .map_err(|error| error.to_string())
        .and_then(|bytes| storage::atomic_write_without_backup(&rotated, &bytes));
    if backup_written.is_ok() {
        writer.file = storage::open_private_truncate(&path).ok();
        writer.bytes_written = 0;
    } else {
        // Preserve the current log if rotation cannot safely create its
        // backup. A later write retries rotation.
        writer.file = storage::open_private_append(&path).ok();
        writer.bytes_written = std::fs::metadata(path).map_or(0, |meta| meta.len());
    }
}

fn truncate_char_boundary(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }
    let mut index = max_bytes;
    while !value.is_char_boundary(index) {
        index -= 1;
    }
    &value[..index]
}
