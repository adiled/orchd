mod cli;
mod config;
mod engine;
mod exec;
mod orchard;
mod orchdi;
mod platform;
mod runtime;
mod types;

use clap::Parser;
use cli::{Cli, Commands};
use config::Config;

fn main() {
    let cli = Cli::parse();

    if let Commands::Tend {
        service: _,
        spec: Some(spec),
        ..
    } = &cli.command
    {
        std::process::exit(orchdi::run(spec));
    }

    let config = Config::load(&cli);

    let result = match &cli.command {
        Commands::Grow {
            services,
            no_start,
            strict,
            force,
        } => engine::grow(&config, services, *no_start, *strict, *force).map_err(boxed),
        Commands::Survey { json } => engine::status(&config, *json).map_err(boxed),
        Commands::Fell { keep_data } => engine::fell(&config, *keep_data).map_err(boxed),
        Commands::Logs {
            service,
            follow,
            lines,
        } => engine::logs(&config, service, *follow, *lines).map_err(boxed),
        Commands::Sow {} => orchard::sow(&config).map_err(boxed_orchard),
        Commands::Plant {} => orchard::plant(&config).map_err(boxed_orchard),
        Commands::Tend {
            service,
            spec,
            no_start,
        } => {
            let path = match (service, spec) {
                (Some(svc), _) => Some(resolve_supervise_spec(&config, svc)),
                (None, Some(p)) => Some(p.clone()),
                (None, None) => None,
            };
            match path {
                Some(p) => std::process::exit(orchdi::run(&p)),
                None => orchard::tend(&config, !*no_start).map_err(boxed_orchard),
            }
        }
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

fn resolve_supervise_spec(config: &Config, service: &str) -> std::path::PathBuf {
    let label = crate::orchdi::service_label(config, service);
    std::path::PathBuf::from(crate::orchdi::supervise_spec_path(config, &label))
}
