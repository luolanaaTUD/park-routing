use sqlx::{FromRow, PgPool};

use crate::error::AppResult;
use crate::models::route::{NavigateResponse, NavigationStep, PathPoint, RouteRequest};

#[derive(FromRow)]
struct DbNavigateRow {
    distance_m: f64,
    duration_sec: i32,
    path_polyline: sqlx::types::Json<Vec<PathPoint>>,
    navigation_steps: sqlx::types::Json<Vec<NavigationStep>>,
}

pub async fn compute_navigation(pool: &PgPool, req: &RouteRequest) -> AppResult<NavigateResponse> {
    let row = sqlx::query_as::<_, DbNavigateRow>(
        r#"
        SELECT
            distance_m,
            duration_sec,
            path_polyline,
            navigation_steps
        FROM navigate_between_points($1, $2, $3, $4, $5, $6)
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

    Ok(NavigateResponse {
        distance_m: row.distance_m,
        duration_sec: row.duration_sec,
        path_polyline: row.path_polyline.0,
        navigation_steps: row.navigation_steps.0,
        cached: false,
    })
}
