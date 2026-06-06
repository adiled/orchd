mod cli;
mod config;
mod engine;
mod exec;
mod orchard;
mod platform;
mod runtime;
mod orchdi;
mod types;

use clap::Parser;
use cli::{Cli, Commands};
use config::Config;

fn main() {
    let cli = Cli::parse();

    // `supervise` is a leaf process (launchd execs it); it doesn't need the
    // full engine config and must run before Config::load to stay lightweight.
    if let Commands::Supervise { spec } = &cli.command {
        std::process::exit(orchdi::run(spec));
    }
    // `containerd-run` is likewise a leaf the supervisor execs: it talks to
    // containerd directly and runs the container in the foreground.
    if let Commands::ContainerdRun { spec } = &cli.command {
        std::process::exit(runtime::containerd::run::run(spec));
    }

    let config = Config::load(&cli);

    let result = match &cli.command {
        Commands::Grow { services, no_start } => {
            engine::grow(&config, services, *no_start).map_err(boxed)
        }
        Commands::Survey { json } => engine::status(&config, *json).map_err(boxed),
        Commands::Fell { keep_data } => engine::fell(&config, *keep_data).map_err(boxed),
        Commands::Logs {
            service,
            follow,
            lines,
        } => engine::logs(&config, service, *follow, *lines).map_err(boxed),
        Commands::Sow {} => orchard::sow(&config).map_err(boxed_orchard),
        Commands::Plant {} => orchard::plant(&config).map_err(boxed_orchard),
        Commands::Tend { no_start } => orchard::tend(&config, !*no_start).map_err(boxed_orchard),
        Commands::Supervise { .. } => unreachable!("handled above"),
        Commands::ContainerdRun { .. } => unreachable!("handled above"),
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}

fn boxed(e: engine::EngineError) -> Box<dyn std::error::Error> {
    Box::new(e)
}

fn boxed_orchard(e: orchard::OrchardError) -> Box<dyn std::error::Error> {
    Box::new(e)
}
