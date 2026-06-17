use serde::{Deserialize, Serialize};
#[allow(unused_imports)]
use serde_json::{Value, json};
use utoipa::ToSchema;

#[derive(Debug, Deserialize, ToSchema)]
pub struct Coordinate {
    pub lon: f64,
    pub lat: f64,
}

#[derive(Debug, Deserialize, ToSchema)]
#[schema(example = json!({
    "start": { "lon": 113.887401, "lat": 22.535316 },
    "end": { "lon": 113.886131, "lat": 22.534781 },
    "travel_mode": "walk",
    "crs": "wgs84"
}))]
pub struct RouteRequest {
    pub start: Coordinate,
    pub end: Coordinate,
    #[serde(default = "default_travel_mode")]
    pub travel_mode: String,
    /// Coordinate reference system for start, end, and response geometry: `gcj02` or `wgs84`.
    pub crs: String,
}

fn default_travel_mode() -> String {
    "walk".into()
}

#[derive(Debug, Serialize, Deserialize, Clone, ToSchema)]
pub struct RouteResponse {
    #[schema(
        value_type = Object,
        example = json!({"type":"LineString","coordinates":[[113.887401,22.535316],[113.886131,22.534781]]})
    )]
    pub geometry: Value,
    #[schema(example = 192.1)]
    pub distance_m: f64,
    #[schema(example = 2.3)]
    pub duration_min: f64,
    pub cached: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
#[schema(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ActionType {
    Start,
    Straight,
    Left,
    Right,
    Destination,
}

#[derive(Debug, Serialize, Deserialize, Clone, ToSchema)]
pub struct PathPoint {
    pub lat: f64,
    pub lon: f64,
}

#[derive(Debug, Serialize, Deserialize, Clone, ToSchema)]
pub struct NavigationStep {
    pub step_index: i32,
    pub lat: f64,
    pub lon: f64,
    pub action_type: ActionType,
    pub guide_text: String,
    pub distance_to_next_m: i32,
}

#[derive(Debug, Serialize, Deserialize, Clone, ToSchema)]
#[schema(example = json!({
    "distance_m": 227.9,
    "duration_sec": 163,
    "path_polyline": [
        { "lat": 22.535316, "lon": 113.887401 },
        { "lat": 22.534781, "lon": 113.886131 }
    ],
    "navigation_steps": [
        {
            "step_index": 0,
            "lat": 22.535316,
            "lon": 113.887401,
            "action_type": "START",
            "guide_text": "沿Route 329直行",
            "distance_to_next_m": 26
        },
        {
            "step_index": 1,
            "lat": 22.534781,
            "lon": 113.886131,
            "action_type": "DESTINATION",
            "guide_text": "到达目的地",
            "distance_to_next_m": 0
        }
    ],
    "cached": false
}))]
pub struct NavigateResponse {
    pub distance_m: f64,
    pub duration_sec: i32,
    pub path_polyline: Vec<PathPoint>,
    pub navigation_steps: Vec<NavigationStep>,
    pub cached: bool,
}

impl RouteRequest {
    pub fn validate(&self) -> Result<(), String> {
        if !matches!(self.travel_mode.as_str(), "walk" | "cart") {
            return Err("travel_mode must be 'walk' or 'cart'".into());
        }
        if !matches!(self.crs.as_str(), "gcj02" | "wgs84") {
            return Err("crs must be 'gcj02' or 'wgs84'".into());
        }
        if !(-180.0..=180.0).contains(&self.start.lon) || !(-90.0..=90.0).contains(&self.start.lat) {
            return Err("start coordinates out of range".into());
        }
        if !(-180.0..=180.0).contains(&self.end.lon) || !(-90.0..=90.0).contains(&self.end.lat) {
            return Err("end coordinates out of range".into());
        }
        Ok(())
    }
}
