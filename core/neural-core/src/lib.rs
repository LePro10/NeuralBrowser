// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! NeuralBrowser core: storage, address-bar input resolution and ad-block rule conversion.

mod error;
pub mod input;
pub mod shield;
pub mod store;
pub mod vault;

pub use error::NeuralError;
pub use input::resolve_input;
pub use store::Store;
pub use vault::Vault;

uniffi::setup_scaffolding!();
