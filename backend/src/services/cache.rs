use deadpool_redis::redis::AsyncCommands;
use deadpool_redis::Pool;

use crate::config::Config;
use crate::error::{AppError, AppResult};
use crate::models::route::{NavigateResponse, RouteRequest, RouteResponse};

pub fn cache_key(req: &RouteRequest, config: &Config) -> String {
    let p = config.cache_grid_precision;
    let factor = 10_f64.powi(p as i32);
    let snap = |v: f64| (v * factor).round() / factor;

    format!(
        "nav:path:{}:{}:{}:{}:{}:{}",
        req.crs,
        req.travel_mode,
        snap(req.start.lon),
        snap(req.start.lat),
        snap(req.end.lon),
        snap(req.end.lat),
    )
}

pub fn navigate_cache_key(req: &RouteRequest, config: &Config) -> String {
    let p = config.cache_grid_precision;
    let factor = 10_f64.powi(p as i32);
    let snap = |v: f64| (v * factor).round() / factor;

    format!(
        "nav:guide:{}:{}:{}:{}:{}:{}",
        req.crs,
        req.travel_mode,
        snap(req.start.lon),
        snap(req.start.lat),
        snap(req.end.lon),
        snap(req.end.lat),
    )
}

pub async fn get_cached(pool: &Pool, key: &str) -> AppResult<Option<RouteResponse>> {
    let mut conn = pool
        .get()
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    let value: Option<String> = conn
        .get(key)
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    match value {
        Some(json) => {
            let mut response: RouteResponse = serde_json::from_str(&json)
                .map_err(|e| AppError::Cache(format!("invalid cache payload: {e}")))?;
            response.cached = true;
            Ok(Some(response))
        }
        None => Ok(None),
    }
}

pub async fn set_cached(
    pool: &Pool,
    key: &str,
    response: &RouteResponse,
    ttl_seconds: u64,
) -> AppResult<()> {
    let mut conn = pool
        .get()
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    let payload = serde_json::to_string(response)
        .map_err(|e| AppError::Cache(format!("serialize cache payload: {e}")))?;

    conn.set_ex::<_, _, ()>(key, payload, ttl_seconds)
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    Ok(())
}

pub fn spawn_cache_write(
    pool: Pool,
    key: String,
    response: RouteResponse,
    ttl_seconds: u64,
) {
    tokio::spawn(async move {
        if let Err(err) = set_cached(&pool, &key, &response, ttl_seconds).await {
            tracing::warn!(error = %err, key = %key, "failed to write route cache");
        }
    });
}

pub async fn get_navigate_cached(pool: &Pool, key: &str) -> AppResult<Option<NavigateResponse>> {
    let mut conn = pool
        .get()
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    let value: Option<String> = conn
        .get(key)
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    match value {
        Some(json) => {
            let mut response: NavigateResponse = serde_json::from_str(&json)
                .map_err(|e| AppError::Cache(format!("invalid cache payload: {e}")))?;
            response.cached = true;
            Ok(Some(response))
        }
        None => Ok(None),
    }
}

pub async fn set_navigate_cached(
    pool: &Pool,
    key: &str,
    response: &NavigateResponse,
    ttl_seconds: u64,
) -> AppResult<()> {
    let mut conn = pool
        .get()
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    let payload = serde_json::to_string(response)
        .map_err(|e| AppError::Cache(format!("serialize cache payload: {e}")))?;

    conn.set_ex::<_, _, ()>(key, payload, ttl_seconds)
        .await
        .map_err(|e| AppError::Cache(e.to_string()))?;

    Ok(())
}

pub fn spawn_navigate_cache_write(
    pool: Pool,
    key: String,
    response: NavigateResponse,
    ttl_seconds: u64,
) {
    tokio::spawn(async move {
        if let Err(err) = set_navigate_cached(&pool, &key, &response, ttl_seconds).await {
            tracing::warn!(error = %err, key = %key, "failed to write navigate cache");
        }
    });
}
