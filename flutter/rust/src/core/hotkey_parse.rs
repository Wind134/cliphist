//! Pure-string shortcut validator.
//!
//! Mirrors `src-tauri shortcut::parse_shortcut`'s accepted/rejected set
//! without depending on `tauri_plugin_global_shortcut` types. Real
//! registration via the `global-hotkey` crate lands in M7 — M2 only needs the
//! boolean "is this a plausible hotkey" check for `validate_hotkey` and for
//! the hotkey field of `update_settings`.
//!
//! Semantics (matching the original): split on `+`, each part is a modifier
//! alias or a key name. The shortcut is valid iff it has at least one
//! modifier AND the *last* key-typed part is a recognized key. So
//! `Ctrl+V` ✅, `V` ❌ (no modifier), `Ctrl+DefinitelyNotAKey` ❌,
//! `Ctrl+BadKey+V` ✅ (last key wins), `Ctrl+V+BadKey` ❌.

#[derive(Default)]
struct Parsed {
    has_ctrl: bool,
    has_meta: bool,
    has_shift: bool,
    has_alt: bool,
    /// `None` = no key-typed part yet; `Some(true)` = last key-typed part was
    /// a known key; `Some(false)` = last key-typed part was unknown. Overwritten
    /// on every key-typed part so the last one wins, exactly like the original
    /// `code` accumulator.
    last_key_known: Option<bool>,
}

pub fn validate_shortcut(shortcut_str: &str) -> bool {
    parse(shortcut_str).is_some()
}

fn parse(shortcut_str: &str) -> Option<Parsed> {
    let parts: Vec<&str> = shortcut_str.split('+').collect();
    if parts.is_empty() {
        return None;
    }

    let mut p = Parsed::default();
    for part in parts {
        match part.trim().to_uppercase().as_str() {
            "COMMANDORCONTROL" | "CMDORCTRL" | "CTRL" => p.has_ctrl = true,
            "COMMAND" | "CMD" | "SUPER" | "META" | "WIN" => p.has_meta = true,
            "SHIFT" => p.has_shift = true,
            "ALT" => p.has_alt = true,
            k => p.last_key_known = Some(is_known_key(k)),
        }
    }

    let has_modifier = p.has_ctrl || p.has_meta || p.has_shift || p.has_alt;
    if !has_modifier {
        return None;
    }
    // Require a known key as the last key-typed part.
    match p.last_key_known {
        Some(true) => Some(p),
        _ => None,
    }
}

fn is_known_key(k: &str) -> bool {
    matches!(
        k,
        "A" | "B"
            | "C"
            | "D"
            | "E"
            | "F"
            | "G"
            | "H"
            | "I"
            | "J"
            | "K"
            | "L"
            | "M"
            | "N"
            | "O"
            | "P"
            | "Q"
            | "R"
            | "S"
            | "T"
            | "U"
            | "V"
            | "W"
            | "X"
            | "Y"
            | "Z"
            | "0"
            | "1"
            | "2"
            | "3"
            | "4"
            | "5"
            | "6"
            | "7"
            | "8"
            | "9"
            | "SPACE"
            | "ENTER"
            | "RETURN"
            | "ESCAPE"
            | "ESC"
            | "TAB"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_a_modifier() {
        assert!(!validate_shortcut("V"));
        assert!(!validate_shortcut(""));
        assert!(validate_shortcut("Ctrl+Shift+V"));
    }

    #[test]
    fn rejects_unknown_keys() {
        assert!(!validate_shortcut("Ctrl+DefinitelyNotAKey"));
    }

    #[test]
    fn accepts_supported_aliases() {
        assert!(validate_shortcut("CmdOrCtrl+Space"));
        assert!(validate_shortcut("Meta+Enter"));
    }

    #[test]
    fn last_key_wins() {
        assert!(validate_shortcut("Ctrl+BadKey+V"));
        assert!(!validate_shortcut("Ctrl+V+BadKey"));
    }

    #[test]
    fn modifier_only_is_invalid() {
        assert!(!validate_shortcut("Ctrl+Shift"));
    }
}
