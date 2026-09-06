//! Private, crash-safe storage primitives shared by history, settings and logs.

use serde::de::DeserializeOwned;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

const DATA_DIR_NAME: &str = "my-cliphist";
const LEGACY_DATA_DIR_NAME: &str = "ClipHist";

/// Prefer `my-cliphist`. If only the pre-rebrand `ClipHist` directory exists,
/// rename it in place so history/settings/images survive the package rename.
fn resolve_data_dir(base: PathBuf) -> PathBuf {
    let new_dir = base.join(DATA_DIR_NAME);
    let legacy_dir = base.join(LEGACY_DATA_DIR_NAME);
    if new_dir.exists() || !legacy_dir.exists() {
        return new_dir;
    }
    match std::fs::rename(&legacy_dir, &new_dir) {
        Ok(()) => new_dir,
        Err(_) => legacy_dir,
    }
}

#[must_use]
pub fn app_data_dir() -> PathBuf {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let base = dirs::data_local_dir()
            .or_else(|| dirs::home_dir().map(|home| home.join(".local").join("share")))
            .unwrap_or_else(|| {
                #[cfg(unix)]
                let identity = unsafe { libc::geteuid() }.to_string();
                #[cfg(not(unix))]
                let identity = std::process::id().to_string();
                std::env::temp_dir().join(format!("my-cliphist-{identity}"))
            });
        resolve_data_dir(base)
    })
    .clone()
}

pub fn ensure_private_dir(path: &Path) -> Result<(), String> {
    std::fs::create_dir_all(path)
        .map_err(|e| format!("Failed to create private directory {path:?}: {e}"))?;
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|e| format!("Failed to inspect private directory {path:?}: {e}"))?;
    if !metadata.file_type().is_dir() {
        return Err(format!(
            "Private storage directory is not a directory: {path:?}"
        ));
    }
    set_private_dir_permissions(path)
}

pub fn ensure_private_file(path: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|e| format!("Failed to inspect private file {path:?}: {e}"))?;
    if !metadata.file_type().is_file() {
        return Err(format!(
            "Private storage path is not a regular file: {path:?}"
        ));
    }
    set_private_file_permissions(path)
}

#[cfg(unix)]
fn set_private_dir_permissions(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("Failed to secure directory {path:?}: {e}"))
}

#[cfg(not(unix))]
fn set_private_dir_permissions(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("Failed to secure file {path:?}: {e}"))
}

#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) -> Result<(), String> {
    Ok(())
}

fn private_create(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|e| format!("Failed to create temporary file {path:?}: {e}"))
}

pub fn open_private_append(path: &Path) -> Result<File, String> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(path)
        .map_err(|e| format!("Failed to open private append file {path:?}: {e}"))?;
    ensure_private_file(path)?;
    Ok(file)
}

pub fn open_private_truncate(path: &Path) -> Result<File, String> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(path)
        .map_err(|e| format!("Failed to open private truncate file {path:?}: {e}"))?;
    ensure_private_file(path)?;
    Ok(file)
}

fn temporary_sibling(path: &Path, suffix: &str) -> Result<PathBuf, String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("Storage path has no parent: {path:?}"))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("Storage path has no UTF-8 file name: {path:?}"))?;
    let sequence = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    Ok(parent.join(format!(
        ".{name}.{}.{}.{}",
        std::process::id(),
        sequence,
        suffix
    )))
}

fn write_synced_temp(path: &Path, bytes: &[u8]) -> Result<PathBuf, String> {
    let temp = temporary_sibling(path, "tmp")?;
    let result = (|| {
        let mut file = private_create(&temp)?;
        file.write_all(bytes)
            .map_err(|e| format!("Failed to write temporary file {temp:?}: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("Failed to sync temporary file {temp:?}: {e}"))?;
        Ok::<(), String>(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temp);
        return Err(error);
    }
    Ok(temp)
}

#[cfg(target_os = "windows")]
fn replace_file(source: &Path, target: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source_wide: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let target_wide: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    let ok = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            target_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        Err(format!(
            "Failed to atomically replace {target:?}: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

#[cfg(not(target_os = "windows"))]
fn replace_file(source: &Path, target: &Path) -> Result<(), String> {
    std::fs::rename(source, target)
        .map_err(|e| format!("Failed to atomically replace {target:?}: {e}"))
}

#[cfg(unix)]
fn sync_parent(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        let directory = File::open(parent)
            .map_err(|e| format!("Failed to open parent directory {parent:?}: {e}"))?;
        directory
            .sync_all()
            .map_err(|e| format!("Failed to sync parent directory {parent:?}: {e}"))?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn sync_parent(_path: &Path) -> Result<(), String> {
    Ok(())
}

fn atomic_write_raw(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("Storage path has no parent: {path:?}"))?;
    ensure_private_dir(parent)?;
    let temp = write_synced_temp(path, bytes)?;
    if let Err(error) = replace_file(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(error);
    }
    ensure_private_file(path)?;
    sync_parent(path)?;
    Ok(())
}

fn backup_path(path: &Path) -> PathBuf {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .map_or_else(|| "bak".to_string(), |value| format!("{value}.bak"));
    path.with_extension(extension)
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if path.exists() {
        ensure_private_file(path)?;
        let previous = std::fs::read(path)
            .map_err(|e| format!("Failed to read previous file {path:?} for backup: {e}"))?;
        atomic_write_raw(&backup_path(path), &previous)?;
    }
    atomic_write_raw(path, bytes)
}

/// Atomically write a file that does not need a second on-disk copy, such as
/// an immutable image blob. JSON state should use [`atomic_write`] instead.
pub fn atomic_write_without_backup(path: &Path, bytes: &[u8]) -> Result<(), String> {
    atomic_write_raw(path, bytes)
}

fn quarantine(path: &Path) -> Result<PathBuf, String> {
    let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ");
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("corrupt");
    let quarantined = path.with_file_name(format!("{name}.corrupt-{timestamp}"));
    std::fs::rename(path, &quarantined)
        .map_err(|e| format!("Failed to quarantine corrupt file {path:?}: {e}"))?;
    ensure_private_file(&quarantined)?;
    Ok(quarantined)
}

fn read_limited(path: &Path, max_bytes: u64) -> Result<Option<Vec<u8>>, String> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("Failed to inspect {path:?}: {error}")),
    };
    if !metadata.file_type().is_file() {
        return Err(format!("Storage path is not a regular file: {path:?}"));
    }
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("Failed to open {path:?}: {error}")),
    };
    if metadata.len() > max_bytes {
        return Err(format!(
            "Storage file {path:?} is too large: {} bytes (limit {max_bytes})",
            metadata.len()
        ));
    }
    let capacity = usize::try_from(metadata.len().min(max_bytes)).unwrap_or(0);
    let mut bytes = Vec::with_capacity(capacity);
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|e| format!("Failed to read {path:?}: {e}"))?;
    if bytes.len() as u64 > max_bytes {
        return Err(format!(
            "Storage file {path:?} grew beyond its {max_bytes}-byte limit while reading"
        ));
    }
    Ok(Some(bytes))
}

pub fn load_json_with_backup<T: DeserializeOwned>(
    path: &Path,
    max_bytes: u64,
) -> Result<Option<T>, String> {
    match read_limited(path, max_bytes) {
        Ok(Some(bytes)) => match serde_json::from_slice(&bytes) {
            Ok(value) => {
                ensure_private_file(path)?;
                return Ok(Some(value));
            }
            Err(error) => {
                let quarantined = quarantine(path)?;
                crate::core::log::write_log(&format!(
                    "Quarantined invalid JSON {path:?} as {quarantined:?}: {error}"
                ));
            }
        },
        Ok(None) => {}
        Err(error) => {
            crate::core::log::write_log(&error);
            let is_regular_file = std::fs::symlink_metadata(path)
                .is_ok_and(|metadata| metadata.file_type().is_file());
            if is_regular_file {
                let quarantined = quarantine(path)?;
                crate::core::log::write_log(&format!(
                    "Quarantined unreadable storage file as {quarantined:?}"
                ));
            }
        }
    }

    let backup = backup_path(path);
    let Some(bytes) = read_limited(&backup, max_bytes)? else {
        return Ok(None);
    };
    let value = serde_json::from_slice(&bytes)
        .map_err(|e| format!("Backup JSON {backup:?} is invalid: {e}"))?;
    atomic_write_raw(path, &bytes)?;
    crate::core::log::write_log(&format!("Recovered {path:?} from {backup:?}"));
    Ok(Some(value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Payload {
        value: u32,
    }

    fn test_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "cliphist-storage-{name}-{}-{}",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn atomic_write_keeps_previous_version_as_backup() {
        let dir = test_dir("backup");
        ensure_private_dir(&dir).unwrap();
        let path = dir.join("value.json");
        atomic_write(&path, br#"{"value":1}"#).unwrap();
        atomic_write(&path, br#"{"value":2}"#).unwrap();

        let current: Payload = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let backup: Payload =
            serde_json::from_slice(&std::fs::read(backup_path(&path)).unwrap()).unwrap();
        assert_eq!(current, Payload { value: 2 });
        assert_eq!(backup, Payload { value: 1 });
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn corrupt_primary_recovers_from_backup() {
        let dir = test_dir("recover");
        ensure_private_dir(&dir).unwrap();
        let path = dir.join("value.json");
        atomic_write(&path, br#"{"value":7}"#).unwrap();
        atomic_write(&path, br#"{"value":8}"#).unwrap();
        std::fs::write(&path, b"{").unwrap();

        let recovered = load_json_with_backup::<Payload>(&path, 1024)
            .unwrap()
            .unwrap();
        assert_eq!(recovered, Payload { value: 7 });
        assert_eq!(
            serde_json::from_slice::<Payload>(&std::fs::read(&path).unwrap()).unwrap(),
            Payload { value: 7 }
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn migrates_legacy_cliphist_data_dir() {
        let base = test_dir("data-dir");
        let legacy = base.join(LEGACY_DATA_DIR_NAME);
        ensure_private_dir(&legacy).unwrap();
        std::fs::write(legacy.join("history.json"), b"[]").unwrap();

        let resolved = resolve_data_dir(base.clone());
        assert_eq!(resolved, base.join(DATA_DIR_NAME));
        assert!(resolved.join("history.json").is_file());
        assert!(!legacy.exists());
        std::fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn keeps_new_data_dir_when_both_exist() {
        let base = test_dir("data-dir-both");
        let legacy = base.join(LEGACY_DATA_DIR_NAME);
        let current = base.join(DATA_DIR_NAME);
        ensure_private_dir(&legacy).unwrap();
        ensure_private_dir(&current).unwrap();
        std::fs::write(current.join("marker"), b"new").unwrap();

        let resolved = resolve_data_dir(base.clone());
        assert_eq!(resolved, current);
        assert!(legacy.exists());
        std::fs::remove_dir_all(base).unwrap();
    }
}
