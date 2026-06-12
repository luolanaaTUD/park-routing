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
    "start": { "lon": 116.388, "lat": 39.988 },
    "end": { "lon": 116.392, "lat": 39.992 },
    "travel_mode": "walk"
}))]
pub struct RouteRequest {
    pub start: Coordinate,
    pub end: Coordinate,
    #[serde(default = "default_travel_mode")]
    pub travel_mode: String,
}

fn default_travel_mode() -> String {
    "walk".into()
}

#[derive(Debug, Serialize, Deserialize, Clone, ToSchema)]
pub struct RouteResponse {
    #[schema(
        value_type = Object,
        example = json!({"type":"LineString","coordinates":[[116.388,39.988],[116.39,39.99],[116.392,39.992]]})
    )]
    pub geometry: Value,
    #[schema(example = 280.16)]
    pub distance_m: f64,
    #[schema(example = 3.3)]
    pub duration_min: f64,
    pub cached: bool,
}

impl RouteRequest {
    pub fn validate(&self) -> Result<(), String> {
        if !matches!(self.travel_mode.as_str(), "walk" | "cart") {
            return Err("travel_mode must be 'walk' or 'cart'".into());
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
