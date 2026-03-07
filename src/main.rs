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
        Commands::Up { services: _, no_generate: _, health_timeout: _ } => {
            stub("up")
        }
        Commands::Down { services: _ } => stub("down"),
        Commands::Restart { services: _ } => stub("restart"),
        Commands::Status { json: _ } => stub("status"),
        Commands::Logs { service: _, follow: _, lines: _ } => stub("logs"),
        Commands::Health { timeout: _, verbose: _ } => stub("health"),
        Commands::List { enabled: _, disabled: _, json: _ } => stub("list"),
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

fn stub(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("{}: not yet implemented", name);
    Ok(())
}
