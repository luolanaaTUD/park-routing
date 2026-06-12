use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use serde_json::json;
use thiserror::Error;
use utoipa::ToSchema;

#[derive(Debug, Serialize, ToSchema)]
pub struct ErrorResponse {
    #[schema(example = "travel_mode must be 'walk' or 'cart'")]
    pub error: String,
}

#[derive(Debug, Error)]
pub enum AppError {
    #[error("validation error: {0}")]
    Validation(String),

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("cache error: {0}")]
    Cache(String),

    #[error("internal error: {0}")]
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            AppError::Validation(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            AppError::Database(err) => {
                if let sqlx::Error::Database(db_err) = err {
                    let code = db_err.code().map(|c| c.to_string()).unwrap_or_default();
                    let msg = db_err.message().to_string();
                    if code == "22023" || code == "P0002" {
                        return (
                            StatusCode::BAD_REQUEST,
                            Json(json!({ "error": msg })),
                        )
                            .into_response();
                    }
                }
                (StatusCode::SERVICE_UNAVAILABLE, "Database unavailable".into())
            }
            AppError::Cache(msg) => (StatusCode::SERVICE_UNAVAILABLE, msg.clone()),
            AppError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg.clone()),
        };

        (status, Json(json!({ "error": message }))).into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;
