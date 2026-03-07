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
        Commands::Generate { force: _ } => cmd_generate(&config),
        Commands::Up {
            services,
            no_generate,
            health_timeout: _,
        } => cmd_up(&config, services, *no_generate),
        Commands::Down { services } => cmd_down(&config, services),
        Commands::Restart { services } => cmd_restart(&config, services),
        Commands::Status { json } => cmd_status(&config, *json),
        Commands::Logs {
            service: _,
            follow: _,
            lines: _,
        } => stub("logs"),
        Commands::Health {
            timeout: _,
            verbose: _,
        } => stub("health"),
        Commands::List {
            enabled: _,
            disabled: _,
            json: _,
        } => stub("list"),
        Commands::Clean { keep_data: _ } => stub("clean"),
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}

fn cmd_generate(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    engine::generate(config)?;
    Ok(())
}

fn cmd_up(
    config: &Config,
    services: &[String],
    no_generate: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    engine::up(config, services, no_generate)?;
    Ok(())
}

fn cmd_down(config: &Config, services: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    engine::down(config, services)?;
    Ok(())
}

fn cmd_restart(config: &Config, services: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    engine::restart(config, services)?;
    Ok(())
}

fn cmd_status(config: &Config, as_json: bool) -> Result<(), Box<dyn std::error::Error>> {
    engine::status(config, as_json)?;
    Ok(())
}

fn stub(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("{}: not yet implemented", name);
    Ok(())
}
