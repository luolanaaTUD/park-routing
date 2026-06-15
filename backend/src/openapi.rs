use utoipa::OpenApi;

use crate::error::ErrorResponse;
use crate::models::route::{
    ActionType, NavigateResponse, NavigationStep, PathPoint, RouteRequest, RouteResponse,
};
use crate::routes::{health, navigate};

#[derive(OpenApi)]
#[openapi(
    info(
        title = "Park Routing API",
        version = "0.1.0",
        description = "Park internal road navigation — path planning with PostGIS/pgRouting and Redis caching."
    ),
    paths(
        health::health,
        navigate::route_handler,
        navigate::navigate_handler,
    ),
    components(schemas(
        RouteRequest,
        RouteResponse,
        NavigateResponse,
        NavigationStep,
        PathPoint,
        ActionType,
        ErrorResponse,
        health::HealthResponse,
    )),
    tags(
        (name = "health", description = "Health check"),
        (name = "routing", description = "Path planning"),
    )
)]
pub struct ApiDoc;
