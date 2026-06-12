use deadpool_redis::Pool as RedisPool;
use sqlx::PgPool;

use crate::config::Config;

#[derive(Clone)]
pub struct AppState {
    pub pg: PgPool,
    pub redis: RedisPool,
    pub config: Config,
}
