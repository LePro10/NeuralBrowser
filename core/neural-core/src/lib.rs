// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! NeuralBrowser core: storage and address-bar input resolution.

mod error;
pub mod input;
pub mod store;

pub use error::NeuralError;
pub use input::resolve_input;
pub use store::Store;

uniffi::setup_scaffolding!();
