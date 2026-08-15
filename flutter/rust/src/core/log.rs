use parking_lot::Mutex;
use std::fs::File;
use std::io::Write;
use std::sync::OnceLock;

pub fn get_log_path() -> std::path::PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("cliphist.log")
}

/// A single append handle reused for the whole process lifetime, instead of
/// open→write→flush→close on every log line. Guarded by a mutex so it's safe
/// to call from any thread. Opened lazily on first use.
static LOG_FILE: OnceLock<Mutex<Option<File>>> = OnceLock::new();

fn handle() -> &'static Mutex<Option<File>> {
    LOG_FILE.get_or_init(|| {
        let f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(get_log_path())
            .ok();
        Mutex::new(f)
    })
}

pub fn write_log(msg: &str) {
    let ts = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
    let mut guard = handle().lock();
    if let Some(file) = guard.as_mut() {
        // A single write keeps the line intact; flush ensures durability for
        // crash diagnostics without reopening the file on every call.
        let _ = writeln!(file, "[{}] {}", ts, msg);
        let _ = file.flush();
    }
}
