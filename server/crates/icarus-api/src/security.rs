//! Response headers (PLAN.md §18). Every response gets the framing, sniffing and referrer
//! headers. HSTS is sent only when the public URL is HTTPS, so plain-HTTP local runs stay usable.

use axum::{
    extract::{Request, State},
    http::{HeaderValue, header},
    middleware::Next,
    response::Response,
};

use crate::state::AppState;

/// The static site needs its own scripts and styles, `data:` images and nothing else. Inline styles
/// are allowed because the UI library sets them at runtime.
pub const WEB_CSP: &str = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'";
const HSTS: &str = "max-age=31536000";

pub async fn set_headers(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    if state.config.public_base_url.starts_with("https://") {
        headers.insert(
            header::STRICT_TRANSPORT_SECURITY,
            HeaderValue::from_static(HSTS),
        );
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csp_matches_the_plan() {
        assert!(WEB_CSP.starts_with("default-src 'self';"));
        assert!(WEB_CSP.contains("frame-ancestors 'none'"));
        assert!(WEB_CSP.contains("base-uri 'none'"));
    }
}
