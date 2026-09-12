/* Malibu is licensed under CPAL-1.0.
 * Copyright (c) 2026 Leon M'laiel. See LICENSE for required attribution. */

#ifndef Malibu_ProofVM_h
#define Malibu_ProofVM_h

#include <stddef.h>
#include <stdint.h>

int spectacles_proof_generate(
    const uint8_t *asset,
    size_t asset_size,
    const uint8_t client_nonce[16],
    const uint8_t peer_nonce[16],
    const uint8_t shared_secret[32],
    uint8_t output[28]
);

#endif
