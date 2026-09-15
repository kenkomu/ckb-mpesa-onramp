#![cfg_attr(not(any(feature = "library", test)), no_std)]
#![cfg_attr(not(test), no_main)]

#[cfg(any(feature = "library", test))]
extern crate alloc;

#[cfg(not(any(feature = "library", test)))]
ckb_std::entry!(program_entry);
#[cfg(not(any(feature = "library", test)))]
ckb_std::default_alloc!(16384, 1258306, 64);

// AlwaysSuccess -- an intentionally permissionless lock, used only as the
// claims-registry cell's own lock script.
//
// The registry cell's actual correctness (append-only, no duplicates) is
// already fully enforced by its own Type Script -- see
// contracts/claims-registry. Locking it with a real key (as an earlier
// devnet iteration did, reusing the deploying key) means every single
// claim transaction needs a co-signature from that one administrative
// key, which is exactly the kind of liveness bottleneck/centralization
// point a "trustless" onramp is supposed to avoid: a buyer's claim
// shouldn't need the seller, or Ken, or anyone else to be online and
// willing to sign. Since the Type Script already gates every mutation
// that matters, the lock has nothing left to check.

pub fn program_entry() -> i8 {
    0
}
