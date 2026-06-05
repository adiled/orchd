mod cli;
mod config;
mod engine;
mod exec;
mod platform;
mod runtime;
mod supervise;
mod types;

use clap::Parser;
use cli::{Cli, Commands};
use config::Config;

fn main() {
    let cli = Cli::parse();

    // `supervise` is a leaf process (launchd execs it); it doesn't need the
    // full engine config and must run before Config::load to stay lightweight.
    if let Commands::Supervise { spec } = &cli.command {
        std::process::exit(supervise::run(spec));
    }

    let config = Config::load(&cli);

    let result = match &cli.command {
        Commands::Generate { force } => engine::generate(&config, *force).map_err(boxed),
        Commands::Up {
            services,
            no_generate,
            health_timeout: _,
        } => engine::up(&config, services, *no_generate).map_err(boxed),
        Commands::Down { services } => engine::down(&config, services).map_err(boxed),
        Commands::Restart { services } => engine::restart(&config, services).map_err(boxed),
        Commands::Status { json } => engine::status(&config, *json).map_err(boxed),
        Commands::Logs {
            service,
            follow,
            lines,
        } => engine::logs(&config, service, *follow, *lines).map_err(boxed),
        Commands::Health { timeout, verbose } => {
            engine::health(&config, timeout, *verbose).map_err(boxed)
        }
        Commands::List {
            enabled,
            disabled,
            json,
        } => engine::list(&config, *enabled, *disabled, *json).map_err(boxed),
        Commands::Clean { keep_data } => engine::clean(&config, *keep_data).map_err(boxed),
        Commands::Supervise { .. } => unreachable!("handled above"),
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}

fn boxed(e: engine::EngineError) -> Box<dyn std::error::Error> {
    Box::new(e)
}
