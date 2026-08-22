//! History commands — 5 of the 11 `#[frb]` functions.

use crate::core::clipboard_engine;
use crate::core::clipboard_engine::ClipboardItem;
use crate::core::events;
use crate::core::state;

/// Full in-memory history, newest first. Synchronous (cheap lock + clone).
#[flutter_rust_bridge::frb(sync)]
pub fn get_history() -> Vec<ClipboardItem> {
    state::st().history.lock().clone()
}

/// Move an existing history item to the front (most-recently-used first) and
/// persist the new order. Triggered by the frontend's number-key quick-paste
/// (1-9) so the just-used entry floats to the top. Other copy actions
/// (double-click, copy button, Enter) intentionally do NOT reorder.
pub fn move_to_top(id: usize) -> Result<(), String> {
    {
        let st = state::st();
        let mut history = st.history.lock();
        let Some(pos) = history.iter().position(|i| i.id == id) else {
            return Err("历史记录不存在".to_string());
        };
        if pos == 0 {
            return Ok(());
        }
        let mut next = history.clone();
        let item = next.remove(pos);
        next.insert(0, item);
        clipboard_engine::save_history(&next)?;
        *history = next;
    }
    events::emit_item_moved_to_top(id);
    Ok(())
}

pub fn delete_item(id: usize) -> Result<(), String> {
    let st = state::st();
    let mut history = st.history.lock();
    let Some(pos) = history.iter().position(|item| item.id == id) else {
        return Err("历史记录不存在".to_string());
    };
    let mut next = history.clone();
    let removed = next.remove(pos);
    clipboard_engine::save_history(&next)?;
    *history = next;
    let snapshot = history.clone();
    drop(history);
    clipboard_engine::delete_image_file(&removed.image_path);
    events::emit_history_replace(snapshot);
    Ok(())
}

pub fn clear_history() -> Result<(), String> {
    let st = state::st();
    let mut history = st.history.lock();
    let images = history
        .iter()
        .map(|item| item.image_path.clone())
        .collect::<Vec<_>>();
    clipboard_engine::save_history(&[])?;
    history.clear();
    drop(history);
    for image in &images {
        clipboard_engine::delete_image_file(image);
    }
    events::emit_history_replace(Vec::new());
    Ok(())
}

/// Load an item's image PNG bytes on demand (FRB maps `Vec<u8>` to `Uint8List`
/// zero-copy). `None` for non-image items or missing files. Only the currently
/// visible images are fetched, keeping memory low.
pub fn get_image_data(id: usize) -> Option<Vec<u8>> {
    let rel = {
        let st = state::st();
        let history = st.history.lock();
        history
            .iter()
            .find(|i| i.id == id)
            .and_then(|i| i.image_path.clone())
    }?;
    clipboard_engine::read_image_file(&rel)
}
