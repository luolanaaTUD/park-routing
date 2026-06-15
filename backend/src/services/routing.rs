use serde_json::Value;
use sqlx::{FromRow, PgPool};

use crate::error::{AppError, AppResult};
use crate::models::route::{RouteRequest, RouteResponse};

#[derive(FromRow)]
struct DbRouteRow {
    geojson: String,
    distance_m: f64,
    duration_min: f64,
}

pub async fn compute_route(pool: &PgPool, req: &RouteRequest) -> AppResult<RouteResponse> {
    let row = sqlx::query_as::<_, DbRouteRow>(
        r#"
        SELECT
            geojson,
            distance_m,
            duration_min
        FROM route_between_points($1, $2, $3, $4, $5, $6)
        "#,
    )
    .bind(req.start.lon)
    .bind(req.start.lat)
    .bind(req.end.lon)
    .bind(req.end.lat)
    .bind(&req.travel_mode)
    .bind(&req.crs)
    .fetch_one(pool)
    .await?;

    let geometry: Value = serde_json::from_str(&row.geojson)
        .map_err(|e| AppError::Internal(format!("invalid GeoJSON from database: {e}")))?;

    Ok(RouteResponse {
        geometry,
        distance_m: row.distance_m,
        duration_min: row.duration_min,
        cached: false,
    })
}
