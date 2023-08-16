use base64;
use rustler::{Atom, Binary, Encoder, Env, OwnedBinary, Term};

mod atoms {
    rustler::atoms! {
        ok,
        invalid,
    }
}

#[rustler::nif]
pub fn decode<'a>(env: Env<'a>, b64: Binary) -> Result<Term<'a>, Atom> {
    let bytes = match base64::decode_config(b64.as_slice(), base64::STANDARD) {
        Ok(v) => v,
        _ => return Err(atoms::invalid()),
    };

    let mut binary = OwnedBinary::new(bytes.len()).unwrap();
    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(Binary::from_owned(binary, env).encode(env))
}

#[rustler::nif]
pub fn encode(s: Binary) -> String {
    base64::encode_config(s.as_slice(), base64::STANDARD)
}

rustler::init!("Elixir.JumpWire.Base64", [decode, encode]);
