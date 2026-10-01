use crate::Record;
use serde::{Deserialize, Serialize};
use specta::Type;

pub type Result<T> = std::result::Result<T, Error>;

/// A stable error envelope. Native CloudKit details survive both transports.
#[derive(Debug, Clone, Serialize, Deserialize, Type, thiserror::Error)]
#[serde(rename_all = "camelCase")]
#[error("{code}: {message}")]
pub struct Error {
    pub code: String,
    pub message: String,
    pub native_code: Option<i32>,
    pub retry_after_seconds: Option<f64>,
    #[serde(default)]
    pub partial_errors: Vec<ItemError>,
    pub server_record: Option<Box<Record>>,
    pub client_record: Option<Box<Record>>,
    pub ancestor_record: Option<Box<Record>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ItemError {
    pub item_id: String,
    pub error: Box<Error>,
}

impl Error {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            native_code: None,
            retry_after_seconds: None,
            partial_errors: vec![],
            server_record: None,
            client_record: None,
            ancestor_record: None,
        }
    }
    pub(crate) fn bridge(error: impl std::fmt::Display) -> Self {
        Self::new("bridgeError", error.to_string())
    }
}
