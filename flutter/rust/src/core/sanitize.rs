//! HTML sanitization at the add-stage.
//!
//! When the clipboard yields rich text we run it through `ammonia` *before*
//! persisting it into `html_content`, so the stored payload is always safe to
//! render. The Dart side (`flutter_widget_from_html`) is kept as a secondary
//! backstop, but the source of truth for safety is here — one CPU pass at
//! capture time, zero cost at every render.

/// Sanitize rich-text HTML captured from the clipboard. Returns an empty
/// string if everything was stripped (caller treats empty as "no rich text").
///
/// Allowlist = inline formatting + block structure + links, on top of
/// ammonia's safe defaults. Relative URLs are denied (no `..`, no bare
/// `/path`), and URL schemes are limited to ammonia's safe set (http/https/
/// mailto) so `javascript:`, `data:` and friends cannot survive. Images are
/// removed to prevent a copied tracking pixel from making a background
/// network request when the history row renders.
pub fn sanitize_html(input: &str) -> String {
    let mut builder = ammonia::Builder::default();
    // Defaults already cover b/i/u/strong/em/s/del/p/br/span/a/code/blockquote.
    // Add the headings, lists, and preformatted blocks the rich view renders.
    builder.add_tags(["h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre"]);
    builder.rm_tags(["img"]);
    // No relative URLs: a captured fragment's `href="/admin"` should not
    // resolve against the app origin.
    builder.url_relative(ammonia::UrlRelative::Deny);
    builder.clean(input).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_script_and_event_handlers() {
        let payload = r#"<p>hi <script>alert(1)</script><b onclick="alert(1)">x</b></p>"#;
        let out = sanitize_html(payload);
        assert!(!out.contains("script"));
        assert!(!out.contains("onclick"));
        assert!(out.contains("<b>x</b>"));
        assert!(out.contains("hi"));
    }

    #[test]
    fn strips_dangerous_embeds() {
        let payload = r#"<iframe src="https://evil"></iframe><object data="x"></object><embed><img src="https://tracker.example/pixel">"#;
        let out = sanitize_html(payload);
        assert!(!out.contains("iframe"));
        assert!(!out.contains("object"));
        assert!(!out.contains("embed"));
        assert!(!out.contains("img"));
        assert!(!out.contains("tracker.example"));
    }

    #[test]
    fn denies_javascript_and_relative_urls() {
        let payload = r##"<a href="javascript:alert(1)">x</a><a href="/admin">admin</a>"##;
        let out = sanitize_html(payload);
        // javascript: is dropped entirely; /admin (relative) is denied.
        assert!(!out.contains("javascript:"));
        assert!(!out.contains("/admin"));
    }

    #[test]
    fn keeps_safe_links_and_structure() {
        let payload = r#"<p>see <a href="https://example.com">ex</a></p><ul><li>a</li></ul>"#;
        let out = sanitize_html(payload);
        assert!(out.contains("https://example.com"));
        assert!(out.contains("<ul>"));
        assert!(out.contains("<li>a</li>"));
    }

    #[test]
    fn empty_payload_yields_empty() {
        assert_eq!(sanitize_html(""), "");
        assert_eq!(sanitize_html("<script>x</script>"), "");
    }
}
