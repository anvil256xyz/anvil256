#pragma once
// =============================================================================
// cpu_cascade.hpp — portable Keccak-Cascade math for the CPU fallback
//
// cascade_hash() mirrors the CUDA hot loop lane-for-lane so a verifier
// mismatch can be audited without translating between two implementations.
//
// Tuning changes vs. previous revision:
//   • [[gnu::hot]] / __attribute__((optimize("O3"))) on cascade_hash so GCC/
//     Clang emit the fastest code even when the TU is built with -O2.
//   • ANVIL256_FORCEINLINE on rotl64 / bswap64 prevents any call overhead
//     inside the macro-expanded round body.
//   • Macro round body is unchanged — intentional, keeps it auditable vs CUDA.
//   • cascade_hash takes const refs to avoid pointer-aliasing penalties when
//     the caller passes stack arrays.
//   • Early-exit ordering: compare h0 first (most likely to differ), then h1,
//     h2, h3.  Identical to the CUDA kernel's fast-reject chain.
// =============================================================================

#include <cstdint>

// Portable force-inline annotation.
#if defined(_MSC_VER)
#  define ANVIL256_FORCEINLINE __forceinline
#elif defined(__GNUC__) || defined(__clang__)
#  define ANVIL256_FORCEINLINE __attribute__((always_inline)) inline
#else
#  define ANVIL256_FORCEINLINE inline
#endif

// Hot-path optimisation hint (GCC / Clang; silently ignored elsewhere).
#if defined(__GNUC__) || defined(__clang__)
#  define ANVIL256_HOT __attribute__((hot))
#else
#  define ANVIL256_HOT
#endif

namespace anvil256::cpu {

ANVIL256_FORCEINLINE std::uint64_t rotl64(std::uint64_t x, int n) {
    return (x << n) | (x >> (64 - n));
}

ANVIL256_FORCEINLINE std::uint64_t bswap64(std::uint64_t v) {
    return ((v & 0x00000000000000FFULL) << 56)
         | ((v & 0x000000000000FF00ULL) << 40)
         | ((v & 0x0000000000FF0000ULL) << 24)
         | ((v & 0x00000000FF000000ULL) <<  8)
         | ((v & 0x000000FF00000000ULL) >>  8)
         | ((v & 0x0000FF0000000000ULL) >> 24)
         | ((v & 0x00FF000000000000ULL) >> 40)
         | ((v & 0xFF00000000000000ULL) >> 56);
}

// ---------------------------------------------------------------------------
// One keccak-f[1600] round, fully register-resident.
// The round constant `rc` is a 64-bit literal → compiler emits XOR-immediate
// instead of a table load (matches CUDA's KECCAK_R behaviour).
// ---------------------------------------------------------------------------
#define ANVIL256_CPU_KECCAK_R(rc)                                                \
    do {                                                                         \
        /* θ */                                                                  \
        const std::uint64_t C0 = a00^a05^a10^a15^a20;                           \
        const std::uint64_t C1 = a01^a06^a11^a16^a21;                           \
        const std::uint64_t C2 = a02^a07^a12^a17^a22;                           \
        const std::uint64_t C3 = a03^a08^a13^a18^a23;                           \
        const std::uint64_t C4 = a04^a09^a14^a19^a24;                           \
        const std::uint64_t D0 = C4^rotl64(C1,1);                               \
        const std::uint64_t D1 = C0^rotl64(C2,1);                               \
        const std::uint64_t D2 = C1^rotl64(C3,1);                               \
        const std::uint64_t D3 = C2^rotl64(C4,1);                               \
        const std::uint64_t D4 = C3^rotl64(C0,1);                               \
        a00^=D0; a05^=D0; a10^=D0; a15^=D0; a20^=D0;                            \
        a01^=D1; a06^=D1; a11^=D1; a16^=D1; a21^=D1;                            \
        a02^=D2; a07^=D2; a12^=D2; a17^=D2; a22^=D2;                            \
        a03^=D3; a08^=D3; a13^=D3; a18^=D3; a23^=D3;                            \
        a04^=D4; a09^=D4; a14^=D4; a19^=D4; a24^=D4;                            \
        /* ρ + π */                                                               \
        const std::uint64_t B00=a00;                                             \
        const std::uint64_t B10=rotl64(a01, 1);                                  \
        const std::uint64_t B20=rotl64(a02,62);                                  \
        const std::uint64_t B05=rotl64(a03,28);                                  \
        const std::uint64_t B15=rotl64(a04,27);                                  \
        const std::uint64_t B16=rotl64(a05,36);                                  \
        const std::uint64_t B01=rotl64(a06,44);                                  \
        const std::uint64_t B11=rotl64(a07, 6);                                  \
        const std::uint64_t B21=rotl64(a08,55);                                  \
        const std::uint64_t B06=rotl64(a09,20);                                  \
        const std::uint64_t B07=rotl64(a10, 3);                                  \
        const std::uint64_t B17=rotl64(a11,10);                                  \
        const std::uint64_t B02=rotl64(a12,43);                                  \
        const std::uint64_t B12=rotl64(a13,25);                                  \
        const std::uint64_t B22=rotl64(a14,39);                                  \
        const std::uint64_t B23=rotl64(a15,41);                                  \
        const std::uint64_t B08=rotl64(a16,45);                                  \
        const std::uint64_t B18=rotl64(a17,15);                                  \
        const std::uint64_t B03=rotl64(a18,21);                                  \
        const std::uint64_t B13=rotl64(a19, 8);                                  \
        const std::uint64_t B14=rotl64(a20,18);                                  \
        const std::uint64_t B24=rotl64(a21, 2);                                  \
        const std::uint64_t B09=rotl64(a22,61);                                  \
        const std::uint64_t B19=rotl64(a23,56);                                  \
        const std::uint64_t B04=rotl64(a24,14);                                  \
        /* χ */                                                                   \
        a00=B00^((~B01)&B02); a01=B01^((~B02)&B03); a02=B02^((~B03)&B04);       \
        a03=B03^((~B04)&B00); a04=B04^((~B00)&B01);                             \
        a05=B05^((~B06)&B07); a06=B06^((~B07)&B08); a07=B07^((~B08)&B09);       \
        a08=B08^((~B09)&B05); a09=B09^((~B05)&B06);                             \
        a10=B10^((~B11)&B12); a11=B11^((~B12)&B13); a12=B12^((~B13)&B14);       \
        a13=B13^((~B14)&B10); a14=B14^((~B10)&B11);                             \
        a15=B15^((~B16)&B17); a16=B16^((~B17)&B18); a17=B17^((~B18)&B19);       \
        a18=B18^((~B19)&B15); a19=B19^((~B15)&B16);                             \
        a20=B20^((~B21)&B22); a21=B21^((~B22)&B23); a22=B22^((~B23)&B24);       \
        a23=B23^((~B24)&B20); a24=B24^((~B20)&B21);                             \
        /* ι */                                                                   \
        a00^=(rc);                                                               \
    } while(0)

#define ANVIL256_CPU_KECCAK_24_ROUNDS                                                                \
    ANVIL256_CPU_KECCAK_R(0x0000000000000001ULL); ANVIL256_CPU_KECCAK_R(0x0000000000008082ULL); \
    ANVIL256_CPU_KECCAK_R(0x800000000000808aULL); ANVIL256_CPU_KECCAK_R(0x8000000080008000ULL); \
    ANVIL256_CPU_KECCAK_R(0x000000000000808bULL); ANVIL256_CPU_KECCAK_R(0x0000000080000001ULL); \
    ANVIL256_CPU_KECCAK_R(0x8000000080008081ULL); ANVIL256_CPU_KECCAK_R(0x8000000000008009ULL); \
    ANVIL256_CPU_KECCAK_R(0x000000000000008aULL); ANVIL256_CPU_KECCAK_R(0x0000000000000088ULL); \
    ANVIL256_CPU_KECCAK_R(0x0000000080008009ULL); ANVIL256_CPU_KECCAK_R(0x000000008000000aULL); \
    ANVIL256_CPU_KECCAK_R(0x000000008000808bULL); ANVIL256_CPU_KECCAK_R(0x800000000000008bULL); \
    ANVIL256_CPU_KECCAK_R(0x8000000000008089ULL); ANVIL256_CPU_KECCAK_R(0x8000000000008003ULL); \
    ANVIL256_CPU_KECCAK_R(0x8000000000008002ULL); ANVIL256_CPU_KECCAK_R(0x8000000000000080ULL); \
    ANVIL256_CPU_KECCAK_R(0x000000000000800aULL); ANVIL256_CPU_KECCAK_R(0x800000008000000aULL); \
    ANVIL256_CPU_KECCAK_R(0x8000000080008081ULL); ANVIL256_CPU_KECCAK_R(0x8000000000008080ULL); \
    ANVIL256_CPU_KECCAK_R(0x0000000080000001ULL); ANVIL256_CPU_KECCAK_R(0x8000000080008008ULL)

// ---------------------------------------------------------------------------
// cascade_hash — κ(m, ν, n) = H(H(ι ‖ ν) ‖ ε[n])
//
// Input layout (matches abi.encode(bytes32, uint256) = 64 bytes per pass):
//   Pass 1: lane[0..3]=inner (LE u64), lane[4..6]=0, lane[7]=bswap64(nonce),
//           lane[8]=0x01, lane[16]=0x8000000000000000, rest=0.
//   Pass 2: lane[0..3]=mid (pass-1 a00..a03), lane[4..7]=entropy (LE u64),
//           lane[8]=0x01, lane[16]=0x8000000000000000, rest=0.
//
// Returns true iff bswap64(a00..a03) < diff[0..3] (uint256 BE compare).
// On return, hash_out[0..3] = BE hash words regardless of pass/fail.
// ---------------------------------------------------------------------------
ANVIL256_HOT
inline bool cascade_hash(
    const std::uint64_t (&inner)[4],
    const std::uint64_t (&entropy)[4],
    const std::uint64_t (&diff)[4],
    std::uint64_t        nonce,
    std::uint64_t        hash_out[4]) noexcept
{
    // ---- Pass 1: mid = keccak256(abi.encode(inner, nonce)) ------------------
    std::uint64_t a00=inner[0], a01=inner[1], a02=inner[2], a03=inner[3];
    std::uint64_t a04=0,        a05=0,        a06=0;
    std::uint64_t a07=bswap64(nonce);
    std::uint64_t a08=1ULL;
    std::uint64_t a09=0,  a10=0,  a11=0,  a12=0;
    std::uint64_t a13=0,  a14=0,  a15=0;
    std::uint64_t a16=0x8000000000000000ULL;
    std::uint64_t a17=0,  a18=0,  a19=0;
    std::uint64_t a20=0,  a21=0,  a22=0,  a23=0,  a24=0;

    ANVIL256_CPU_KECCAK_24_ROUNDS;

    // ---- Pass 2: result = keccak256(abi.encode(mid, entropy)) --------------
    // a00..a03 = mid already; load entropy into a04..a07.
    a04=entropy[0]; a05=entropy[1]; a06=entropy[2]; a07=entropy[3];
    a08=1ULL;
    a09=0;  a10=0;  a11=0;  a12=0;
    a13=0;  a14=0;  a15=0;
    a16=0x8000000000000000ULL;
    a17=0;  a18=0;  a19=0;
    a20=0;  a21=0;  a22=0;  a23=0;  a24=0;

    ANVIL256_CPU_KECCAK_24_ROUNDS;

    // ---- BE hash words + fast-reject uint256 compare -----------------------
    const std::uint64_t h0=bswap64(a00), h1=bswap64(a01),
                        h2=bswap64(a02), h3=bswap64(a03);
    hash_out[0]=h0; hash_out[1]=h1; hash_out[2]=h2; hash_out[3]=h3;

    if (h0 != diff[0]) return h0 < diff[0];
    if (h1 != diff[1]) return h1 < diff[1];
    if (h2 != diff[2]) return h2 < diff[2];
    return h3 <  diff[3];
}

#undef ANVIL256_CPU_KECCAK_R
#undef ANVIL256_CPU_KECCAK_24_ROUNDS

} // namespace anvil256::cpu