use k256::ecdsa::SigningKey;
use k256::elliptic_curve::sec1::ToEncodedPoint;

fn main() {
    let sk = SigningKey::random(&mut rand::thread_rng());
    let vk = sk.verifying_key();
    let compressed = vk.to_encoded_point(true);
    let pubkey_bytes = compressed.as_bytes();

    let mut blake2b = ckb_hash::new_blake2b();
    blake2b.update(pubkey_bytes);
    let mut digest = [0u8; 32];
    blake2b.finalize(&mut digest);
    let blake160 = &digest[0..20];

    println!("private_key=0x{}", hex::encode(sk.to_bytes()));
    println!("pubkey_compressed=0x{}", hex::encode(pubkey_bytes));
    println!("lock_args_blake160=0x{}", hex::encode(blake160));
}
