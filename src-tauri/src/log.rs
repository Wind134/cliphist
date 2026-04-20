use std::io::Write;

pub fn get_log_path() -> std::path::PathBuf {
    let data_dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ClipHist");
    std::fs::create_dir_all(&data_dir).ok();
    data_dir.join("cliphist.log")
}

pub fn write_log(msg: &str) {
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(get_log_path())
    {
        let ts = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
        let _ = writeln!(file, "[{}] {}", ts, msg);
        let _ = file.flush();
    }
}
