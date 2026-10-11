use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use omega_notch_core::sessions;
use omega_notch_core::UsageStore;
use serde_json::{json, Value};
use tokio::net::TcpListener;

pub async fn serve_hooks(store: UsageStore) -> anyhow::Result<()> {
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/hooks/session", post(session_hook))
        .with_state(store);

    // Localhost only — Claude Code hooks / helpers post here.
    let listener = TcpListener::bind("127.0.0.1:17337").await?;
    tracing::info!("hook HTTP on http://127.0.0.1:17337");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn session_hook(
    State(store): State<UsageStore>,
    body: String,
) -> Result<Json<Value>, StatusCode> {
    let event = sessions::parse_hook_payload(&body).map_err(|_| StatusCode::BAD_REQUEST)?;
    store.ingest_hook(event).await;
    Ok(Json(json!({ "ok": true })))
}
