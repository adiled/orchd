mod cli;
mod config;
mod engine;
mod exec;
mod platform;
mod runtime;
mod types;

use clap::Parser;
use cli::{Cli, Commands};
use config::Config;

fn main() {
    let cli = Cli::parse();
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
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}

fn boxed(e: engine::EngineError) -> Box<dyn std::error::Error> {
    Box::new(e)
}
