use axum::{Json, extract::State, http::StatusCode};
use deadpool_redis::redis::AsyncCommands;
use serde::Serialize;
use utoipa::ToSchema;

use crate::error::AppResult;
use crate::state::AppState;

#[derive(Debug, Serialize, ToSchema)]
pub struct HealthResponse {
    #[schema(example = "ok")]
    pub status: String,
    #[schema(example = "ok")]
    pub postgres: String,
    #[schema(example = "PONG")]
    pub redis: String,
}

#[utoipa::path(
    get,
    path = "/health",
    tag = "health",
    responses(
        (status = 200, description = "Service and dependencies are healthy", body = HealthResponse),
        (status = 503, description = "Postgres or Redis unavailable", body = crate::error::ErrorResponse),
    )
)]
pub async fn health(State(state): State<AppState>) -> AppResult<(StatusCode, Json<HealthResponse>)> {
    sqlx::query("SELECT 1")
        .fetch_one(&state.pg)
        .await?;

    let mut redis = state
        .redis
        .get()
        .await
        .map_err(|e| crate::error::AppError::Cache(e.to_string()))?;
    let pong: String = redis
        .ping()
        .await
        .map_err(|e| crate::error::AppError::Cache(e.to_string()))?;

    Ok((
        StatusCode::OK,
        Json(HealthResponse {
            status: "ok".into(),
            postgres: "ok".into(),
            redis: pong,
        }),
    ))
}
