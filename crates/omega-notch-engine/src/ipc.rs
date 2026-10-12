use std::path::PathBuf;

use omega_notch_core::protocol::{
    ClientMessage, ServerMessage, ENGINE_NAME, PROTOCOL_VERSION,
};
use omega_notch_core::jump::{self, ChatTarget};
use omega_notch_core::UsageStore;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

pub async fn serve(path: PathBuf, store: UsageStore) -> anyhow::Result<()> {
    let listener = UnixListener::bind(&path)?;
    info!(path = %path.display(), "unix socket ready");

    loop {
        let (stream, _) = listener.accept().await?;
        let store = store.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_client(stream, store).await {
                debug!(error = %err, "client disconnected");
            }
        });
    }
}

async fn handle_client(stream: UnixStream, store: UsageStore) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let mut events = store.subscribe();
    let mut subscribed = false;

    // Hello first.
    write_msg(
        &mut writer,
        &ServerMessage::Hello {
            server: ENGINE_NAME.into(),
            version: 1,
            protocol: PROTOCOL_VERSION,
        },
    )
    .await?;

    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { break; };
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<ClientMessage>(&line) {
                    Ok(msg) => {
                        if let Err(err) = handle_message(msg, &store, &mut writer, &mut subscribed).await {
                            write_msg(
                                &mut writer,
                                &ServerMessage::Error { message: err.to_string() },
                            ).await?;
                        }
                    }
                    Err(err) => {
                        write_msg(
                            &mut writer,
                            &ServerMessage::Error {
                                message: format!("bad client message: {err}"),
                            },
                        ).await?;
                    }
                }
            }
            event = events.recv() => {
                match event {
                    Ok(msg) => {
                        if subscribed {
                            write_msg(&mut writer, &msg).await?;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(skipped = n, "client lagged; sending fresh snapshot");
                        if subscribed {
                            write_msg(&mut writer, &store.snapshot().await).await?;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }

    Ok(())
}

async fn handle_message(
    msg: ClientMessage,
    store: &UsageStore,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    subscribed: &mut bool,
) -> anyhow::Result<()> {
    match msg {
        ClientMessage::Hello { client, version } => {
            debug!(client, version, "client hello");
            write_msg(
                writer,
                &ServerMessage::Hello {
                    server: ENGINE_NAME.into(),
                    version: 1,
                    protocol: PROTOCOL_VERSION,
                },
            )
            .await?;
        }
        ClientMessage::Subscribe => {
            *subscribed = true;
            write_msg(writer, &store.snapshot().await).await?;
        }
        ClientMessage::GetSnapshot => {
            write_msg(writer, &store.snapshot().await).await?;
        }
        ClientMessage::Refresh { provider } => {
            if let Some(id) = provider {
                store.refresh_one(id).await;
            } else {
                store.refresh_all().await;
            }
            write_msg(writer, &store.snapshot().await).await?;
        }
        ClientMessage::GetConfig => {
            let config = store.config().await;
            write_msg(writer, &ServerMessage::ConfigUpdated { config }).await?;
        }
        ClientMessage::SetConfig { config } => {
            store.set_config(config).await?;
        }
        ClientMessage::CopilotSignIn => {
            store.copilot_sign_in();
        }
        ClientMessage::OpenChat { provider, id, cwd, title, surface } => {
            // Raising windows shells out and may wait for a new one to appear.
            tokio::task::spawn_blocking(move || {
                let target = ChatTarget {
                    provider,
                    id: &id,
                    cwd: cwd.as_deref(),
                    title: title.as_deref(),
                    surface: surface.as_deref(),
                };
                if let Err(err) = jump::open_chat(&target) {
                    warn!(error = %err, id, "could not open chat");
                }
            });
        }
        ClientMessage::GetDashboard { days } => {
            write_msg(writer, &store.dashboard(days).await).await?;
        }
        ClientMessage::Ping => {
            write_msg(writer, &ServerMessage::Pong).await?;
        }
    }
    Ok(())
}

async fn write_msg(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    msg: &ServerMessage,
) -> anyhow::Result<()> {
    let mut line = serde_json::to_string(msg)?;
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    Ok(())
}
