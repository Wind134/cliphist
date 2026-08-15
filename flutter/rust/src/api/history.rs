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
pub fn move_to_top(id: usize) {
    {
        let st = state::st();
        let mut history = st.history.lock();
        let Some(pos) = history.iter().position(|i| i.id == id) else {
            return;
        };
        if pos == 0 {
            return;
        }
        let it = history.remove(pos);
        history.insert(0, it);
        // Keep persistence ordered with every other history mutation.
        clipboard_engine::save_history(&history);
    }
    events::emit_item_moved_to_top(id);
}

pub fn delete_item(id: usize) {
    let st = state::st();
    let mut history = st.history.lock();
    if let Some(pos) = history.iter().position(|item| item.id == id) {
        let removed = history.remove(pos);
        clipboard_engine::delete_image_file(&removed.image_path);
    }
    clipboard_engine::save_history(&history);
}

pub fn clear_history() {
    let st = state::st();
    let mut history = st.history.lock();
    for item in history.iter() {
        clipboard_engine::delete_image_file(&item.image_path);
    }
    history.clear();
    clipboard_engine::save_history(&history);
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
