mod hooks;
mod ipc;

use clap::{Parser, Subcommand};
use omega_notch_core::config::AppConfig;
use omega_notch_core::paths;
use omega_notch_core::UsageStore;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(
    name = "omega-notch-engine",
    version,
    about = "Omega Notch usage engine"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Run the engine (default).
    Serve,
    /// Print local diagnostics for providers and paths.
    Doctor,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    init_tracing();

    match cli.command.unwrap_or(Commands::Serve) {
        Commands::Doctor => {
            print!("{}", omega_notch_core::doctor::run_doctor().await);
            Ok(())
        }
        Commands::Serve => serve().await,
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,omega_notch_core=info,omega_notch_engine=info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}

async fn serve() -> anyhow::Result<()> {
    paths::migrate_legacy_dirs();
    paths::create_private_dir(&paths::app_config_dir())?;
    paths::create_private_dir(&paths::app_data_dir())?;
    std::fs::create_dir_all(paths::app_data_dir().join("hooks"))?;

    let config = AppConfig::load();
    let store = UsageStore::new(config);
    store.clone().spawn_background();

    let hook_store = store.clone();
    tokio::spawn(async move {
        if let Err(err) = hooks::serve_hooks(hook_store).await {
            tracing::warn!(error = %err, "hook HTTP server stopped");
        }
    });

    let sock = paths::socket_path();
    if sock.exists() {
        let _ = std::fs::remove_file(&sock);
    }

    info!(path = %sock.display(), "listening");
    ipc::serve(sock, store).await
}
