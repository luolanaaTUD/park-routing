use axum::{Json, extract::State};

use crate::error::{AppError, AppResult};
use crate::models::route::{NavigateResponse, RouteRequest, RouteResponse};
use crate::services::cache::{
    cache_key, get_cached, get_navigate_cached, navigate_cache_key, spawn_cache_write,
    spawn_navigate_cache_write,
};
use crate::services::navigation::compute_navigation;
use crate::services::routing::compute_route;
use crate::state::AppState;

#[utoipa::path(
    post,
    path = "/api/v1/route",
    tag = "routing",
    request_body = RouteRequest,
    responses(
        (status = 200, description = "Route computed (or served from cache)", body = RouteResponse),
        (status = 400, description = "Invalid input or no route found", body = crate::error::ErrorResponse),
        (status = 503, description = "Database or cache unavailable", body = crate::error::ErrorResponse),
    )
)]
pub async fn route_handler(
    State(state): State<AppState>,
    Json(req): Json<RouteRequest>,
) -> AppResult<Json<RouteResponse>> {
    req.validate()
        .map_err(AppError::Validation)?;

    let key = cache_key(&req, &state.config);

    if let Some(cached) = get_cached(&state.redis, &key).await? {
        tracing::debug!(key = %key, "route cache hit");
        return Ok(Json(cached));
    }

    tracing::debug!(key = %key, "route cache miss");
    let response = compute_route(&state.pg, &req).await?;

    let cache_response = response.clone();
    spawn_cache_write(
        state.redis.clone(),
        key,
        cache_response,
        state.config.cache_ttl_seconds,
    );

    Ok(Json(response))
}

#[utoipa::path(
    post,
    path = "/api/v1/navigate",
    tag = "routing",
    request_body = RouteRequest,
    responses(
        (status = 200, description = "Navigation with turn-by-turn steps (or served from cache)", body = NavigateResponse),
        (status = 400, description = "Invalid input or no route found", body = crate::error::ErrorResponse),
        (status = 503, description = "Database or cache unavailable", body = crate::error::ErrorResponse),
    )
)]
pub async fn navigate_handler(
    State(state): State<AppState>,
    Json(req): Json<RouteRequest>,
) -> AppResult<Json<NavigateResponse>> {
    req.validate()
        .map_err(AppError::Validation)?;

    let key = navigate_cache_key(&req, &state.config);

    if let Some(cached) = get_navigate_cached(&state.redis, &key).await? {
        tracing::debug!(key = %key, "navigate cache hit");
        return Ok(Json(cached));
    }

    tracing::debug!(key = %key, "navigate cache miss");
    let response = compute_navigation(&state.pg, &req).await?;

    let cache_response = response.clone();
    spawn_navigate_cache_write(
        state.redis.clone(),
        key,
        cache_response,
        state.config.cache_ttl_seconds,
    );

    Ok(Json(response))
}
