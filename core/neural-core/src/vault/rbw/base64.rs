// Copied from rbw 1.15.0 (https://github.com/doy/rbw, commit 77464d4), src/base64.rs.
// Copyright (c) 2021 Jesse Luehrs, MIT license (see LICENSE in this directory).
// Edits are listed in mod.rs.

use base64::Engine as _;

pub fn encode<T: AsRef<[u8]>>(input: T) -> String {
    base64::engine::general_purpose::STANDARD.encode(input)
}

pub fn encode_url_safe_no_pad<T: AsRef<[u8]>>(input: T) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(input)
}

pub fn decode<T: AsRef<[u8]>>(
    input: T,
) -> Result<Vec<u8>, base64::DecodeError> {
    base64::engine::general_purpose::STANDARD.decode(input)
}
