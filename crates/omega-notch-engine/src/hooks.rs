use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use omega_notch_core::sessions;
use omega_notch_core::UsageStore;
use serde_json::{json, Value};
use tokio::net::TcpListener;

const PORT: u16 = 17337;

pub async fn serve_hooks(store: UsageStore) -> anyhow::Result<()> {
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/hooks/session", post(session_hook))
        .with_state(store);

    // Localhost only — Claude Code hooks / helpers post here.
    let listener = TcpListener::bind(("127.0.0.1", PORT)).await?;
    tracing::info!("hook HTTP on http://127.0.0.1:{PORT}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn session_hook(
    State(store): State<UsageStore>,
    headers: HeaderMap,
    body: String,
) -> Result<Json<Value>, StatusCode> {
    check_local_client(&headers)?;
    let event = sessions::parse_hook_payload(&body).map_err(|_| StatusCode::BAD_REQUEST)?;
    store.ingest_hook(event).await;
    Ok(Json(json!({ "ok": true })))
}

/// Hooks come from local tools such as curl, never from a browser. Listening
/// on 127.0.0.1 does not keep web pages out: any page can send a "simple"
/// cross-origin POST, and DNS rebinding can make one same-origin. So:
/// - a browser always sends `Origin` on a POST; local tools do not;
/// - `application/json` is not a simple content type, so a page cannot send
///   it cross-origin without a preflight, which this server never answers;
/// - `Host` must name this server, which a rebound domain does not.
fn check_local_client(headers: &HeaderMap) -> Result<(), StatusCode> {
    if headers.contains_key(header::ORIGIN) {
        return Err(StatusCode::FORBIDDEN);
    }
    let host = headers.get(header::HOST).and_then(|h| h.to_str().ok());
    let local_hosts = [format!("127.0.0.1:{PORT}"), format!("localhost:{PORT}")];
    if !host.is_some_and(|h| local_hosts.iter().any(|l| l.eq_ignore_ascii_case(h))) {
        return Err(StatusCode::FORBIDDEN);
    }
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|h| h.to_str().ok());
    let is_json = content_type
        .and_then(|c| c.split(';').next())
        .is_some_and(|c| c.trim().eq_ignore_ascii_case("application/json"));
    if !is_json {
        return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(header::HeaderName, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.insert(name.clone(), value.parse().unwrap());
        }
        map
    }

    #[test]
    fn accepts_curl_from_the_hook_script() {
        let h = headers(&[
            (header::HOST, "127.0.0.1:17337"),
            (header::CONTENT_TYPE, "application/json"),
        ]);
        assert_eq!(check_local_client(&h), Ok(()));
        let h = headers(&[
            (header::HOST, "localhost:17337"),
            (header::CONTENT_TYPE, "Application/JSON; charset=utf-8"),
        ]);
        assert_eq!(check_local_client(&h), Ok(()));
    }

    #[test]
    fn rejects_web_pages() {
        let h = headers(&[
            (header::HOST, "127.0.0.1:17337"),
            (header::CONTENT_TYPE, "application/json"),
            (header::ORIGIN, "https://evil.example"),
        ]);
        assert_eq!(check_local_client(&h), Err(StatusCode::FORBIDDEN));
        let h = headers(&[
            (header::HOST, "127.0.0.1:17337"),
            (header::CONTENT_TYPE, "application/json"),
            (header::ORIGIN, "null"),
        ]);
        assert_eq!(check_local_client(&h), Err(StatusCode::FORBIDDEN));
    }

    #[test]
    fn rejects_rebound_hosts() {
        let h = headers(&[
            (header::HOST, "evil.example:17337"),
            (header::CONTENT_TYPE, "application/json"),
        ]);
        assert_eq!(check_local_client(&h), Err(StatusCode::FORBIDDEN));
        let h = headers(&[(header::CONTENT_TYPE, "application/json")]);
        assert_eq!(check_local_client(&h), Err(StatusCode::FORBIDDEN));
    }

    #[test]
    fn rejects_simple_content_types() {
        for ct in [
            "text/plain",
            "application/x-www-form-urlencoded",
            "multipart/form-data",
        ] {
            let h = headers(&[
                (header::HOST, "127.0.0.1:17337"),
                (header::CONTENT_TYPE, ct),
            ]);
            assert_eq!(
                check_local_client(&h),
                Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
            );
        }
        let h = headers(&[(header::HOST, "127.0.0.1:17337")]);
        assert_eq!(
            check_local_client(&h),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
    }
}
