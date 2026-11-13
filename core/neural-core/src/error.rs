// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Error type exposed to all platform shells.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum NeuralError {
    /// The underlying database reported an error.
    #[error("database error: {message}")]
    Database { message: String },
    /// The caller passed an invalid argument.
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
    /// Internal invariant violated (e.g. poisoned lock).
    #[error("internal error: {message}")]
    Internal { message: String },
}

impl From<rusqlite::Error> for NeuralError {
    fn from(e: rusqlite::Error) -> Self {
        NeuralError::Database {
            message: e.to_string(),
        }
    }
}
