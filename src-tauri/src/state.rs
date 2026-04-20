use std::sync::Arc;

use parking_lot::Mutex;

use crate::clipboard::ClipboardItem;

#[derive(Default)]
pub struct AppState {
    pub history: Arc<Mutex<Vec<ClipboardItem>>>,
    pub counter: Arc<Mutex<usize>>,
}
