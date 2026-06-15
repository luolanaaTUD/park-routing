mod config;
mod error;
mod models;
mod openapi;
mod routes;
mod services;
mod state;

use axum::{
    Router,
    routing::{get, post},
};
use deadpool_redis::{Config as RedisConfig, Runtime};
use sqlx::postgres::PgPoolOptions;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use crate::config::Config;
use crate::openapi::ApiDoc;
use crate::routes::{health, navigate};
use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer())
        .init();

    let config = Config::from_env();

    let pg = PgPoolOptions::new()
        .max_connections(config.pg_pool_max_connections)
        .connect(&config.database_url)
        .await?;

    let redis_cfg = RedisConfig::from_url(config.redis_url.clone());
    let redis = redis_cfg
        .create_pool(Some(Runtime::Tokio1))
        .map_err(|e| format!("redis pool: {e}"))?;
    redis.resize(config.redis_pool_max_size);

    let state = AppState {
        pg,
        redis,
        config: config.clone(),
    };

    let app = Router::new()
        .merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
        .route("/health", get(health::health))
        .route("/api/v1/route", post(navigate::route_handler))
        .route("/api/v1/navigate", post(navigate::navigate_handler))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&config.listen_addr).await?;
    tracing::info!(addr = %config.listen_addr, "park-routing API listening");

    axum::serve(listener, app).await?;
    Ok(())
}
