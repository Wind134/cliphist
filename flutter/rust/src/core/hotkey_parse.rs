//! Pure-string shortcut validator.
//!
//! Keeps validation independent from the platform hotkey plugin. It provides
//! the boolean "is this a plausible hotkey" check used by `validate_hotkey`
//! and the hotkey field of `update_settings`.
//!
//! Semantics: split on `+`, each part is a modifier
//! alias or a key name. The shortcut is valid iff it has at least one
//! modifier AND exactly one recognized key. So
//! `Ctrl+V` ✅, `V` ❌ (no modifier), `Ctrl+DefinitelyNotAKey` ❌,
//! `Ctrl+BadKey+V` ❌, and `Ctrl+V+X` ❌.

#[derive(Default)]
struct Parsed {
    has_ctrl: bool,
    has_meta: bool,
    has_shift: bool,
    has_alt: bool,
    has_key: bool,
}

pub fn validate_shortcut(shortcut_str: &str) -> bool {
    parse(shortcut_str).is_some()
}

fn parse(shortcut_str: &str) -> Option<Parsed> {
    if shortcut_str.is_empty() {
        return None;
    }

    let mut p = Parsed::default();
    for part in shortcut_str.split('+') {
        if part.trim().is_empty() {
            return None;
        }
        match part.trim().to_uppercase().as_str() {
            "COMMANDORCONTROL" | "CMDORCTRL" | "CTRL" | "CONTROL" if !p.has_ctrl => {
                p.has_ctrl = true;
            }
            "COMMAND" | "CMD" | "SUPER" | "META" | "WIN" if !p.has_meta => p.has_meta = true,
            "SHIFT" if !p.has_shift => p.has_shift = true,
            "ALT" | "OPTION" if !p.has_alt => p.has_alt = true,
            key if !p.has_key && is_known_key(key) => p.has_key = true,
            _ => return None,
        }
    }

    let has_modifier = p.has_ctrl || p.has_meta || p.has_shift || p.has_alt;
    if !has_modifier {
        return None;
    }
    if p.has_key {
        Some(p)
    } else {
        None
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
            | "BACKSPACE"
            | "F1"
            | "F2"
            | "F3"
            | "F4"
            | "F5"
            | "F6"
            | "F7"
            | "F8"
            | "F9"
            | "F10"
            | "F11"
            | "F12"
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
    fn rejects_multiple_or_empty_keys() {
        assert!(!validate_shortcut("Ctrl+BadKey+V"));
        assert!(!validate_shortcut("Ctrl+V+BadKey"));
        assert!(!validate_shortcut("Ctrl+V+X"));
        assert!(!validate_shortcut("Ctrl++V"));
    }

    #[test]
    fn modifier_only_is_invalid() {
        assert!(!validate_shortcut("Ctrl+Shift"));
    }

    #[test]
    fn matches_frontend_named_keys_and_aliases() {
        assert!(validate_shortcut("Control+Backspace"));
        assert!(validate_shortcut("Option+F12"));
    }
}
