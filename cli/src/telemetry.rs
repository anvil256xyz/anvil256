//! Tracing setup. Picks text or JSON output based on LOG_FORMAT env.

use tracing_subscriber::{fmt, prelude::*, EnvFilter};

pub fn init(log_format: &str) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"));

    let registry = tracing_subscriber::registry().with(filter);

    match log_format {
        "json" => {
            registry.with(fmt::layer().json().with_target(false)).init();
        }
        _ => {
            registry
                .with(fmt::layer().with_target(false).compact())
                .init();
        }
    }
}
