// =============================================================================
// miner.cu — high-performance CUDA GPU miner for Anvil256 Cascade PoW
//
// Drop-in replacement for the previous CUDA build. Same stdin/stdout JSON
// protocol; the JOB line now carries three hex32 values to match the
// on-chain Cascade verifier in Anvil256.sol::_cascadeHash.
//
// =============================================================================
// PoW model (matches Anvil256.sol::_cascadeHash on Base L2)
// =============================================================================
//   inner   = getInner(miner)             // ι(m, n), supplied by host
//   entropy = epochEntropy                // ε[n],     supplied by host
//   mid     = keccak256(abi.encode(inner, nonce))      // 64-byte input
//   result  = keccak256(abi.encode(mid,   entropy))    // 64-byte input
//   valid iff uint256(result) < currentDifficulty
//
// abi.encode(bytes32, uint256) packs to 64 bytes (single keccak-256 block):
//   bytes [ 0..32) = bytes32 raw 32 bytes
//   bytes [32..64) = uint256 big-endian
// abi.encode(bytes32, bytes32) packs identically (raw 32 || raw 32).
//
// State lanes (each = LE uint64) for the 1600-bit absorb (each pass):
//   Pass 1 (inner ‖ nonce_be32):
//     lane[0..3]  = inner    bytes 0..31  as 4 LE u64
//     lane[4..6]  = 0                    (high 24 bytes of uint256 nonce)
//     lane[7]     = bswap64(nonce_u64)    (low  8 bytes of uint256 nonce)
//     lane[8]     = 0x01                  // pad10*1 first bit
//     lane[16]    = 0x8000000000000000    // pad10*1 last bit
//     all others  = 0
//   Pass 2 (mid ‖ entropy):
//     lane[0..3]  = mid      bytes 0..31  (= pass-1 output lanes a00..a03)
//     lane[4..7]  = entropy  bytes 0..31  as 4 LE u64
//     lane[8]     = 0x01
//     lane[16]    = 0x8000000000000000
//     all others  = 0
//
// Apply keccak-f[1600] once per pass. After pass 2, hash = lane[0..3].
//
// =============================================================================
// What is tuned in this revision
// =============================================================================
//   * __launch_bounds__(128, 4): caps registers at 128/thread and aims for
//     >=4 blocks/SM. Sweet spot for register-resident keccak on sm_75..sm_90.
//   * inner, entropy and difficulty live in __constant__ memory — broadcast-
//     cached on every warp read, frees registers vs. kernel args.
//   * Two keccak passes inlined back-to-back into the same register-resident
//     state. The second pass reuses the lanes that pass 1 leaves in place.
//   * 24 keccak rounds expanded with the round constant materialised as a
//     64-bit literal (no array index, no constant-memory load for RC); ptxas
//     emits XOR.B64 with an immediate operand.
//   * PRMT-based bswap64 via __byte_perm -> 2 PRMT instructions per bswap.
//   * Dropped the per-iteration `result->found` check inside the per-thread
//     nonce loop; the host always cudaMemsetAsyncs the result before every
//     launch, so the only `found` write happens via atomicCAS on a real win.
//   * Host I/O is fully asynchronous: cudaMemsetAsync (reset), kernel, then
//     cudaMemcpyAsync (DtoH) into a pinned-host buffer; one stream per device
//     is synchronized only after the memcpy, never between kernels.
//   * Adaptive grid size AND adaptive nonces-per-thread: ramps toward
//     MINER_TARGET_BATCH_MS (default 250 ms) and backs off if a batch ever
//     overshoots 4x the target.
//
// =============================================================================
// Build
// =============================================================================
// Linux / WSL2 (CUDA toolkit 12.x or 11.8+):
//   nvcc -O3 -std=c++17 -Xcompiler -pthread \
//        -arch=sm_89 \                       # native Ada Lovelace (4060 Ti)
//        miner.cu -o miner
//
//   # multi-arch fat-binary (covers Turing..Hopper plus forward-PTX):
//   nvcc -O3 -std=c++17 -Xcompiler -pthread \
//        -gencode arch=compute_75,code=sm_75 \
//        -gencode arch=compute_80,code=sm_80 \
//        -gencode arch=compute_86,code=sm_86 \
//        -gencode arch=compute_89,code=sm_89 \
//        -gencode arch=compute_90,code=sm_90 \
//        -gencode arch=compute_100,code=sm_100 \
//        -gencode arch=compute_120,code=sm_120 \
//        -gencode arch=compute_120,code=compute_120 \
//        miner.cu -o miner
//
// Windows native (Visual Studio 2022 + CUDA 12.x):
//   nvcc -O3 -std=c++17 -arch=sm_89 miner.cu -o miner.exe
//
// =============================================================================
// CLI
// =============================================================================
//   Interactive (used by the Rust host main.rs):
//     ./miner                           # reads JSON commands from stdin
//
//   One-shot (ad-hoc benchmarks):
//     ./miner --once <inner_hex32> <entropy_hex32> <difficulty_hex32>
//
// Env vars:
//   MINER_DEVICES=0,1            comma list of CUDA device indices
//   MINER_BLOCK=128              CUDA block size  (default 128, max 256)
//   MINER_GRID=0                 CUDA grid size   (default = auto, SM*64)
//   MINER_NPT=128                nonces per thread (default 128)
//   MINER_TARGET_BATCH_MS=250    auto-tune target per-launch ms
//   MINER_PROGRESS_MS=750        progress emit period in ms
//
// RTX 50-series note:
//   Build with CUDA 12.8+ and ARCHS="75 80 86 89 90 100 120". The sm_120
//   target covers consumer Blackwell cards such as RTX 5060/5070/5080/5090,
//   while compute_120 PTX keeps the binary forward-compatible with later
//   Blackwell driver/toolkit revisions.
//
// Stdin protocol (one ASCII line per command):
//   JOB <inner_hex32> <entropy_hex32> <difficulty_hex32> <job_id>
//   STOP
//   EXIT
//
// Stdout protocol (one JSON object per line, flushed immediately):
//   {"type":"ready","devices":[{"index":0,"name":"...","cu":34,"wg":128, ...}]}
//   {"type":"progress","job":N,"device":"...","hashes":N,"hashrate":N,"elapsed_ms":N}
//   {"type":"found","job":N,"device":"...","nonce":"DEC","hash":"0x...","hashes":N,"hashrate":N,"elapsed_ms":N}
//   {"type":"error","message":"..."}
// =============================================================================

#include <cuda_runtime.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// =============================================================================
// Keccak-256 — device kernel
// =============================================================================

// Inner-hash lanes (ι), epoch-entropy lanes (ε), and difficulty words live in
// constant memory; copied once per JOB and broadcast-cached on every SM.
//   d_INNER[i] = LE u64 of inner   bytes [8i .. 8i+8)
//   d_EPS[i]   = LE u64 of entropy bytes [8i .. 8i+8)
//   d_DIFF[i]  = BE u64 of difficulty ([0] = most-significant 8 bytes)
__constant__ std::uint64_t d_INNER[4];
__constant__ std::uint64_t d_EPS[4];
__constant__ std::uint64_t d_DIFF[4];

struct alignas(16) Result {
    unsigned int  found;
    unsigned int  pad;
    std::uint64_t nonce;
    std::uint64_t hash[4];   // big-endian word order: hash[0] = MSB
};

__device__ __forceinline__ std::uint64_t rotl64(std::uint64_t x, int n) {
    // ptxas folds this into SHF.L.WRAP.B32 pairs (1-cycle 64-bit funnel-shift
    // on sm_70+).
    return (x << n) | (x >> (64 - n));
}

__device__ __forceinline__ std::uint64_t bswap64(std::uint64_t v) {
    // PRMT-based byte reverse: 2 PRMT instructions for the entire 64-bit word.
    std::uint32_t hi = (std::uint32_t)(v >> 32);
    std::uint32_t lo = (std::uint32_t)v;
    std::uint32_t hi_out = __byte_perm(lo, 0u, 0x0123u);   // bswap(lo) -> top
    std::uint32_t lo_out = __byte_perm(hi, 0u, 0x0123u);   // bswap(hi) -> bot
    return ((std::uint64_t)hi_out << 32) | lo_out;
}

// One keccak-f[1600] round over 25 named registers. `rc` is a 64-bit literal
// so ptxas emits XOR.B64 with an immediate operand (no constant-memory load).
#define KECCAK_R(rc)                                                            \
    do {                                                                        \
        const std::uint64_t C0 = a00 ^ a05 ^ a10 ^ a15 ^ a20;                   \
        const std::uint64_t C1 = a01 ^ a06 ^ a11 ^ a16 ^ a21;                   \
        const std::uint64_t C2 = a02 ^ a07 ^ a12 ^ a17 ^ a22;                   \
        const std::uint64_t C3 = a03 ^ a08 ^ a13 ^ a18 ^ a23;                   \
        const std::uint64_t C4 = a04 ^ a09 ^ a14 ^ a19 ^ a24;                   \
        const std::uint64_t D0 = C4 ^ rotl64(C1, 1);                            \
        const std::uint64_t D1 = C0 ^ rotl64(C2, 1);                            \
        const std::uint64_t D2 = C1 ^ rotl64(C3, 1);                            \
        const std::uint64_t D3 = C2 ^ rotl64(C4, 1);                            \
        const std::uint64_t D4 = C3 ^ rotl64(C0, 1);                            \
        a00 ^= D0; a05 ^= D0; a10 ^= D0; a15 ^= D0; a20 ^= D0;                  \
        a01 ^= D1; a06 ^= D1; a11 ^= D1; a16 ^= D1; a21 ^= D1;                  \
        a02 ^= D2; a07 ^= D2; a12 ^= D2; a17 ^= D2; a22 ^= D2;                  \
        a03 ^= D3; a08 ^= D3; a13 ^= D3; a18 ^= D3; a23 ^= D3;                  \
        a04 ^= D4; a09 ^= D4; a14 ^= D4; a19 ^= D4; a24 ^= D4;                  \
        const std::uint64_t B00 = a00;                                          \
        const std::uint64_t B10 = rotl64(a01,  1);                              \
        const std::uint64_t B20 = rotl64(a02, 62);                              \
        const std::uint64_t B05 = rotl64(a03, 28);                              \
        const std::uint64_t B15 = rotl64(a04, 27);                              \
        const std::uint64_t B16 = rotl64(a05, 36);                              \
        const std::uint64_t B01 = rotl64(a06, 44);                              \
        const std::uint64_t B11 = rotl64(a07,  6);                              \
        const std::uint64_t B21 = rotl64(a08, 55);                              \
        const std::uint64_t B06 = rotl64(a09, 20);                              \
        const std::uint64_t B07 = rotl64(a10,  3);                              \
        const std::uint64_t B17 = rotl64(a11, 10);                              \
        const std::uint64_t B02 = rotl64(a12, 43);                              \
        const std::uint64_t B12 = rotl64(a13, 25);                              \
        const std::uint64_t B22 = rotl64(a14, 39);                              \
        const std::uint64_t B23 = rotl64(a15, 41);                              \
        const std::uint64_t B08 = rotl64(a16, 45);                              \
        const std::uint64_t B18 = rotl64(a17, 15);                              \
        const std::uint64_t B03 = rotl64(a18, 21);                              \
        const std::uint64_t B13 = rotl64(a19,  8);                              \
        const std::uint64_t B14 = rotl64(a20, 18);                              \
        const std::uint64_t B24 = rotl64(a21,  2);                              \
        const std::uint64_t B09 = rotl64(a22, 61);                              \
        const std::uint64_t B19 = rotl64(a23, 56);                              \
        const std::uint64_t B04 = rotl64(a24, 14);                              \
        a00 = B00 ^ ((~B01) & B02);                                             \
        a01 = B01 ^ ((~B02) & B03);                                             \
        a02 = B02 ^ ((~B03) & B04);                                             \
        a03 = B03 ^ ((~B04) & B00);                                             \
        a04 = B04 ^ ((~B00) & B01);                                             \
        a05 = B05 ^ ((~B06) & B07);                                             \
        a06 = B06 ^ ((~B07) & B08);                                             \
        a07 = B07 ^ ((~B08) & B09);                                             \
        a08 = B08 ^ ((~B09) & B05);                                             \
        a09 = B09 ^ ((~B05) & B06);                                             \
        a10 = B10 ^ ((~B11) & B12);                                             \
        a11 = B11 ^ ((~B12) & B13);                                             \
        a12 = B12 ^ ((~B13) & B14);                                             \
        a13 = B13 ^ ((~B14) & B10);                                             \
        a14 = B14 ^ ((~B10) & B11);                                             \
        a15 = B15 ^ ((~B16) & B17);                                             \
        a16 = B16 ^ ((~B17) & B18);                                             \
        a17 = B17 ^ ((~B18) & B19);                                             \
        a18 = B18 ^ ((~B19) & B15);                                             \
        a19 = B19 ^ ((~B15) & B16);                                             \
        a20 = B20 ^ ((~B21) & B22);                                             \
        a21 = B21 ^ ((~B22) & B23);                                             \
        a22 = B22 ^ ((~B23) & B24);                                             \
        a23 = B23 ^ ((~B24) & B20);                                             \
        a24 = B24 ^ ((~B20) & B21);                                             \
        a00 ^= rc;                                                              \
    } while (0)

#define KECCAK_24_ROUNDS                                                        \
    KECCAK_R(0x0000000000000001ULL); KECCAK_R(0x0000000000008082ULL);           \
    KECCAK_R(0x800000000000808aULL); KECCAK_R(0x8000000080008000ULL);           \
    KECCAK_R(0x000000000000808bULL); KECCAK_R(0x0000000080000001ULL);           \
    KECCAK_R(0x8000000080008081ULL); KECCAK_R(0x8000000000008009ULL);           \
    KECCAK_R(0x000000000000008aULL); KECCAK_R(0x0000000000000088ULL);           \
    KECCAK_R(0x0000000080008009ULL); KECCAK_R(0x000000008000000aULL);           \
    KECCAK_R(0x000000008000808bULL); KECCAK_R(0x800000000000008bULL);           \
    KECCAK_R(0x8000000000008089ULL); KECCAK_R(0x8000000000008003ULL);           \
    KECCAK_R(0x8000000000008002ULL); KECCAK_R(0x8000000000000080ULL);           \
    KECCAK_R(0x000000000000800aULL); KECCAK_R(0x800000008000000aULL);           \
    KECCAK_R(0x8000000080008081ULL); KECCAK_R(0x8000000000008080ULL);           \
    KECCAK_R(0x0000000080000001ULL); KECCAK_R(0x8000000080008008ULL)

// __launch_bounds__(maxThreadsPerBlock, minBlocksPerSM):
// 128 thr/blk * 4 blk/SM = 512 thr/SM = 16 warps/SM, capped at 128 regs/thread.
__global__ __launch_bounds__(128, 4)
void mine_kernel(
    const std::uint64_t base_nonce,
    const std::uint32_t nonces_per_thread,
    Result* __restrict__ result)
{
    const std::uint64_t tid   = (std::uint64_t)blockIdx.x * (std::uint64_t)blockDim.x
                              + (std::uint64_t)threadIdx.x;
    const std::uint64_t start = base_nonce + tid * (std::uint64_t)nonces_per_thread;

    // Inner-hash and entropy lanes (LE u64).
    const std::uint64_t i0 = d_INNER[0], i1 = d_INNER[1],
                        i2 = d_INNER[2], i3 = d_INNER[3];
    const std::uint64_t e0 = d_EPS[0],   e1 = d_EPS[1],
                        e2 = d_EPS[2],   e3 = d_EPS[3];
    // Difficulty words (BE).
    const std::uint64_t df0 = d_DIFF[0], df1 = d_DIFF[1],
                        df2 = d_DIFF[2], df3 = d_DIFF[3];

    #pragma unroll 1
    for (std::uint32_t k = 0; k < nonces_per_thread; ++k) {
        const std::uint64_t nonce = start + (std::uint64_t)k;

        // =====================================================================
        // Pass 1: mid = keccak256(abi.encode(inner, nonce))
        //   bytes [ 0..32) = inner
        //   bytes [32..56) = 0       (high 24 bytes of uint256 nonce)
        //   bytes [56..64) = bswap64(nonce_u64)  (low 8 bytes BE)
        //   pad10*1 starts at byte 64 (lane 8, bit 0) and ends at byte 135.
        // =====================================================================
        std::uint64_t a00 = i0,        a01 = i1,        a02 = i2,        a03 = i3;
        std::uint64_t a04 = 0ULL,      a05 = 0ULL,      a06 = 0ULL;
        std::uint64_t a07 = bswap64(nonce);
        std::uint64_t a08 = 1ULL;
        std::uint64_t a09 = 0ULL,      a10 = 0ULL,      a11 = 0ULL,      a12 = 0ULL;
        std::uint64_t a13 = 0ULL,      a14 = 0ULL,      a15 = 0ULL;
        std::uint64_t a16 = 0x8000000000000000ULL;
        std::uint64_t a17 = 0ULL,      a18 = 0ULL,      a19 = 0ULL;
        std::uint64_t a20 = 0ULL,      a21 = 0ULL,      a22 = 0ULL,
                      a23 = 0ULL,      a24 = 0ULL;

        KECCAK_24_ROUNDS;

        // Pass 1 output occupies a00..a03 (LE u64 lanes of mid).
        const std::uint64_t m0 = a00, m1 = a01, m2 = a02, m3 = a03;

        // =====================================================================
        // Pass 2: result = keccak256(abi.encode(mid, epochEntropy))
        //   bytes [ 0..32) = mid
        //   bytes [32..64) = entropy
        //   pad10*1 starts at byte 64 (lane 8) and ends at byte 135.
        // =====================================================================
        a00 = m0; a01 = m1; a02 = m2; a03 = m3;
        a04 = e0; a05 = e1; a06 = e2; a07 = e3;
        a08 = 1ULL;
        a09 = 0ULL; a10 = 0ULL; a11 = 0ULL; a12 = 0ULL;
        a13 = 0ULL; a14 = 0ULL; a15 = 0ULL;
        a16 = 0x8000000000000000ULL;
        a17 = 0ULL; a18 = 0ULL; a19 = 0ULL;
        a20 = 0ULL; a21 = 0ULL; a22 = 0ULL; a23 = 0ULL; a24 = 0ULL;

        KECCAK_24_ROUNDS;

        // ----- BE compare with short-circuit fast-reject --------------------
        const std::uint64_t h0 = bswap64(a00);
        if (h0 > df0) continue;
        if (h0 == df0) {
            const std::uint64_t h1 = bswap64(a01);
            if (h1 > df1) continue;
            if (h1 == df1) {
                const std::uint64_t h2 = bswap64(a02);
                if (h2 > df2) continue;
                if (h2 == df2) {
                    const std::uint64_t h3 = bswap64(a03);
                    if (h3 >= df3) continue;
                    if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                        result->nonce   = nonce;
                        result->hash[0] = h0;
                        result->hash[1] = h1;
                        result->hash[2] = h2;
                        result->hash[3] = h3;
                    }
                    return;
                }
                if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                    result->nonce   = nonce;
                    result->hash[0] = h0;
                    result->hash[1] = h1;
                    result->hash[2] = h2;
                    result->hash[3] = bswap64(a03);
                }
                return;
            }
            if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                result->nonce   = nonce;
                result->hash[0] = h0;
                result->hash[1] = h1;
                result->hash[2] = bswap64(a02);
                result->hash[3] = bswap64(a03);
            }
            return;
        }
        if (atomicCAS(&result->found, 0u, 1u) == 0u) {
            result->nonce   = nonce;
            result->hash[0] = h0;
            result->hash[1] = bswap64(a01);
            result->hash[2] = bswap64(a02);
            result->hash[3] = bswap64(a03);
        }
        return;
    }
}

// =============================================================================
// Host helpers
// =============================================================================

namespace {

constexpr std::uint32_t DEFAULT_BLOCK   = 128;
constexpr std::uint32_t DEFAULT_NPT     = 128;
constexpr std::uint32_t MIN_NPT         = 1;
constexpr std::uint32_t MAX_NPT         = 4096;
constexpr std::uint32_t MAX_BLOCK       = 256;     // matches __launch_bounds__ ceiling
constexpr std::uint64_t DEFAULT_PROG_MS = 750;
constexpr std::uint64_t DEVICE_NONCE_WINDOW = 1ULL << 56;
constexpr double        DEFAULT_TGT_MS  = 250.0;
constexpr double        EMA_ALPHA       = 0.30;

std::mutex g_io_mu;

inline std::string trim(const std::string& s) {
    auto b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    auto e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c & 0xff);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

void emit(const std::string& line) {
    std::lock_guard<std::mutex> lk(g_io_mu);
    std::cout << line << '\n';
    std::cout.flush();
}

void emit_error(const std::string& msg) {
    std::ostringstream os;
    os << "{\"type\":\"error\",\"message\":\"" << json_escape(msg) << "\"}";
    emit(os.str());
}

int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool parse_hex32(const std::string& s, std::uint8_t out[32]) {
    const char* p = s.c_str();
    std::size_t n = s.size();
    if (n >= 2 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) { p += 2; n -= 2; }
    if (n != 64) return false;
    for (std::size_t i = 0; i < 32; ++i) {
        int hi = hex_nibble(p[i * 2]);
        int lo = hex_nibble(p[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<std::uint8_t>((hi << 4) | lo);
    }
    return true;
}

std::uint64_t load_le64(const std::uint8_t* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= static_cast<std::uint64_t>(p[i]) << (i * 8);
    return v;
}

std::uint64_t load_be64(const std::uint8_t* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | static_cast<std::uint64_t>(p[i]);
    return v;
}

std::string hash_to_hex(const std::uint64_t hash[4]) {
    char buf[2 + 64 + 1];
    char* p = buf;
    *p++ = '0';
    *p++ = 'x';
    for (int i = 0; i < 4; ++i) {
        std::uint64_t w = hash[i];
        for (int b = 7; b >= 0; --b) {
            std::uint8_t byte = static_cast<std::uint8_t>(w >> (b * 8));
            std::snprintf(p, 3, "%02x", byte);
            p += 2;
        }
    }
    *p = '\0';
    return std::string(buf);
}

std::string u64_to_dec(std::uint64_t v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%" PRIu64, v);
    return std::string(buf);
}

std::uint64_t env_u64(const char* name, std::uint64_t fallback) {
    const char* v = std::getenv(name);
    if (!v || !*v) return fallback;
    char* end = nullptr;
    unsigned long long r = std::strtoull(v, &end, 0);
    if (end == v) return fallback;
    return static_cast<std::uint64_t>(r);
}

double env_f64(const char* name, double fallback) {
    const char* v = std::getenv(name);
    if (!v || !*v) return fallback;
    char* end = nullptr;
    double r = std::strtod(v, &end);
    if (end == v) return fallback;
    return r;
}

std::vector<std::size_t> env_csv_indices(const char* name) {
    std::vector<std::size_t> out;
    const char* v = std::getenv(name);
    if (!v || !*v) return out;
    std::string s = v;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        item = trim(item);
        if (item.empty()) continue;
        char* end = nullptr;
        unsigned long idx = std::strtoul(item.c_str(), &end, 10);
        if (end != item.c_str()) out.push_back(static_cast<std::size_t>(idx));
    }
    return out;
}

std::uint64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

bool cuda_check(cudaError_t e, const char* where, std::string& msg) {
    if (e == cudaSuccess) return true;
    std::ostringstream os;
    os << where << ": " << cudaGetErrorString(e) << " (" << (int)e << ")";
    msg = os.str();
    return false;
}

// =============================================================================
// Job & shared state
// =============================================================================

struct Job {
    std::uint64_t id            = 0;
    std::uint64_t inner[4]      = {};   // LE u64 lanes of ι
    std::uint64_t entropy[4]    = {};   // LE u64 lanes of ε[n]
    std::uint64_t difficulty[4] = {};   // BE u64 words ([0]=MSB)
    std::uint64_t base_nonce    = 0;
    bool          active        = false;
};

struct SharedState {
    std::mutex              mu;
    std::condition_variable cv;
    Job                     job;
    std::uint64_t           next_job_id = 1;
    std::atomic<bool>       found_in_job{false};
    std::atomic<bool>       exit_requested{false};
};

SharedState* g_state_ptr = nullptr;

void handle_signal(int) {
    if (g_state_ptr) {
        g_state_ptr->exit_requested.store(true, std::memory_order_release);
        g_state_ptr->cv.notify_all();
    }
}

// =============================================================================
// Per-device CUDA context
// =============================================================================

struct DeviceCtx {
    int           device_id     = 0;
    std::size_t   index         = 0;
    std::string   name;
    int           sm_count      = 0;
    int           max_threads   = 1024;
    std::uint32_t block_size    = DEFAULT_BLOCK;
    std::uint32_t grid_size     = 0;          // blocks per launch
    std::uint32_t npt           = DEFAULT_NPT;
    std::uint64_t device_stride = 0;          // nonce-space offset per device
    std::uint64_t window_used   = 0;          // hashes consumed inside stride window
    double        target_ms     = DEFAULT_TGT_MS;

    cudaStream_t  stream        = nullptr;
    Result*       d_result      = nullptr;    // device result buffer
    Result*       h_result      = nullptr;    // pinned host result buffer
};

bool init_device(DeviceCtx& d, std::string& err) {
    if (!cuda_check(cudaSetDevice(d.device_id), "cudaSetDevice", err)) return false;

    cudaDeviceProp prop{};
    if (!cuda_check(cudaGetDeviceProperties(&prop, d.device_id),
                    "cudaGetDeviceProperties", err)) return false;
    d.name        = prop.name;
    d.sm_count    = prop.multiProcessorCount;
    d.max_threads = prop.maxThreadsPerBlock;

    // ---- env-driven tuning, clamped to safe ranges -------------------------
    std::uint32_t blk = (std::uint32_t)env_u64("MINER_BLOCK", DEFAULT_BLOCK);
    if (blk > MAX_BLOCK) blk = MAX_BLOCK;
    if ((int)blk > d.max_threads) blk = (std::uint32_t)d.max_threads;
    if (blk == 0) blk = DEFAULT_BLOCK;
    if (blk % 32 != 0) blk = (blk / 32) * 32;
    if (blk < 32) blk = 32;
    d.block_size = blk;

    std::uint32_t npt = (std::uint32_t)env_u64("MINER_NPT", DEFAULT_NPT);
    if (npt < MIN_NPT) npt = MIN_NPT;
    if (npt > MAX_NPT) npt = MAX_NPT;
    d.npt = npt;

    std::uint64_t env_grid = env_u64("MINER_GRID", 0);
    if (env_grid == 0) {
        // Auto: SM_count * 64 blocks. With block=128 this keeps every SM
        // oversubscribed by at least 4 ready waves after the first launch.
        d.grid_size = (std::uint32_t)(d.sm_count * 64);
        if (d.grid_size < 64) d.grid_size = 64;
    } else {
        d.grid_size = (std::uint32_t)env_grid;
    }

    d.target_ms = env_f64("MINER_TARGET_BATCH_MS", DEFAULT_TGT_MS);
    if (d.target_ms < 25.0)   d.target_ms = 25.0;
    if (d.target_ms > 2000.0) d.target_ms = 2000.0;

    // ---- allocations -------------------------------------------------------
    if (!cuda_check(cudaStreamCreateWithFlags(&d.stream, cudaStreamNonBlocking),
                    "cudaStreamCreate", err)) return false;
    if (!cuda_check(cudaMalloc(&d.d_result, sizeof(Result)),
                    "cudaMalloc(d_result)", err)) return false;
    if (!cuda_check(cudaHostAlloc((void**)&d.h_result, sizeof(Result),
                                  cudaHostAllocDefault),
                    "cudaHostAlloc(h_result)", err)) return false;

    return true;
}

void release_device(DeviceCtx& d) {
    cudaSetDevice(d.device_id);
    if (d.d_result) { cudaFree(d.d_result);        d.d_result = nullptr; }
    if (d.h_result) { cudaFreeHost(d.h_result);    d.h_result = nullptr; }
    if (d.stream)   { cudaStreamDestroy(d.stream); d.stream   = nullptr; }
}

// =============================================================================
// Device worker thread
// =============================================================================

void device_worker(DeviceCtx d, SharedState* st) {
    cudaSetDevice(d.device_id);

    std::uint64_t local_job_id   = 0;
    std::uint64_t job_started_ms = 0;
    std::uint64_t job_hashes     = 0;
    double        hashrate_ema   = 0.0;
    std::uint64_t last_emit_ms   = 0;
    std::uint64_t base_nonce     = 0;
    bool          have_job       = false;

    const std::uint64_t prog_period = env_u64("MINER_PROGRESS_MS", DEFAULT_PROG_MS);

    while (!st->exit_requested.load(std::memory_order_acquire)) {
        std::uint64_t inner[4] = {};
        std::uint64_t eps[4]   = {};
        std::uint64_t diff[4]  = {};

        // ---- wait for an active job ----------------------------------------
        {
            std::unique_lock<std::mutex> lk(st->mu);
            st->cv.wait(lk, [&]{
                return st->exit_requested.load() ||
                       (st->job.active && st->job.id != local_job_id);
            });
            if (st->exit_requested.load()) break;

            const Job& j = st->job;
            local_job_id   = j.id;
            for (int i = 0; i < 4; ++i) inner[i] = j.inner[i];
            for (int i = 0; i < 4; ++i) eps[i]   = j.entropy[i];
            for (int i = 0; i < 4; ++i) diff[i]  = j.difficulty[i];
            base_nonce     = j.base_nonce + d.device_stride;
            d.window_used  = 0;
            have_job       = true;
            job_started_ms = now_ms();
            job_hashes     = 0;
            hashrate_ema   = 0.0;
            last_emit_ms   = job_started_ms;
            st->found_in_job.store(false, std::memory_order_release);
        }

        // ---- push inner + entropy + difficulty into constant memory --------
        {
            std::string err;
            if (!cuda_check(cudaMemcpyToSymbolAsync(d_INNER, inner, sizeof(inner), 0,
                                                   cudaMemcpyHostToDevice, d.stream),
                            "cudaMemcpyToSymbolAsync(d_INNER)", err)) {
                emit_error(err); have_job = false; continue;
            }
            if (!cuda_check(cudaMemcpyToSymbolAsync(d_EPS, eps, sizeof(eps), 0,
                                                   cudaMemcpyHostToDevice, d.stream),
                            "cudaMemcpyToSymbolAsync(d_EPS)", err)) {
                emit_error(err); have_job = false; continue;
            }
            if (!cuda_check(cudaMemcpyToSymbolAsync(d_DIFF, diff, sizeof(diff), 0,
                                                   cudaMemcpyHostToDevice, d.stream),
                            "cudaMemcpyToSymbolAsync(d_DIFF)", err)) {
                emit_error(err); have_job = false; continue;
            }
        }

        // ---- mining loop ----------------------------------------------------
        while (have_job && !st->exit_requested.load(std::memory_order_acquire)) {
            {
                std::lock_guard<std::mutex> lk(st->mu);
                if (st->job.id != local_job_id || !st->job.active) { have_job = false; break; }
            }
            if (st->found_in_job.load(std::memory_order_acquire)) { have_job = false; break; }

            std::string err;

            if (!cuda_check(cudaMemsetAsync(d.d_result, 0, sizeof(Result), d.stream),
                            "cudaMemsetAsync(d_result)", err)) { emit_error(err); have_job = false; break; }

            const std::uint64_t batch_started = now_ms();

            mine_kernel<<<d.grid_size, d.block_size, 0, d.stream>>>(
                base_nonce, d.npt, d.d_result);

            if (!cuda_check(cudaGetLastError(), "kernel launch", err)) { emit_error(err); have_job = false; break; }

            if (!cuda_check(cudaMemcpyAsync(d.h_result, d.d_result, sizeof(Result),
                                            cudaMemcpyDeviceToHost, d.stream),
                            "cudaMemcpyAsync(d_result)", err)) { emit_error(err); have_job = false; break; }

            if (!cuda_check(cudaStreamSynchronize(d.stream),
                            "cudaStreamSynchronize", err)) { emit_error(err); have_job = false; break; }

            const std::uint64_t now      = now_ms();
            std::uint64_t       batch_ms = now - batch_started;
            if (batch_ms == 0) batch_ms = 1;

            const std::uint64_t did = (std::uint64_t)d.grid_size *
                                      (std::uint64_t)d.block_size *
                                      (std::uint64_t)d.npt;
            if (did == 0 || d.window_used > DEVICE_NONCE_WINDOW - did) {
                std::ostringstream os;
                os << "device nonce window exhausted for " << d.name
                   << "; restart job to avoid cross-device nonce overlap";
                emit_error(os.str());
                have_job = false;
                break;
            }
            job_hashes += did;
            base_nonce += did;
            d.window_used += did;

            const double rate = (double)did * 1000.0 / (double)batch_ms;
            hashrate_ema = (hashrate_ema == 0.0)
                ? rate
                : (EMA_ALPHA * rate + (1.0 - EMA_ALPHA) * hashrate_ema);

            // ---- adaptive grid + NPT auto-tune toward target_ms ------------
            if ((double)batch_ms < d.target_ms * 0.5) {
                double scale = d.target_ms / (double)batch_ms;
                if (d.grid_size < (std::uint32_t)(d.sm_count * 1024)) {
                    std::uint64_t target = (std::uint64_t)((double)d.grid_size * scale);
                    if (target > (std::uint64_t)d.grid_size * 4ULL)
                        target = (std::uint64_t)d.grid_size * 4ULL;
                    if (target > (std::uint64_t)d.sm_count * 1024ULL)
                        target = (std::uint64_t)d.sm_count * 1024ULL;
                    d.grid_size = (std::uint32_t)target;
                } else if (d.npt < MAX_NPT) {
                    std::uint64_t target = (std::uint64_t)((double)d.npt * scale);
                    if (target > (std::uint64_t)d.npt * 2ULL) target = (std::uint64_t)d.npt * 2ULL;
                    if (target > (std::uint64_t)MAX_NPT)      target = MAX_NPT;
                    d.npt = (std::uint32_t)target;
                }
            } else if ((double)batch_ms > d.target_ms * 4.0) {
                if (d.npt > MIN_NPT) {
                    std::uint64_t target = (std::uint64_t)((double)d.npt * d.target_ms / (double)batch_ms);
                    if (target < MIN_NPT) target = MIN_NPT;
                    d.npt = (std::uint32_t)target;
                } else if (d.grid_size > (std::uint32_t)d.sm_count) {
                    std::uint64_t target = (std::uint64_t)((double)d.grid_size * d.target_ms / (double)batch_ms);
                    if (target < (std::uint64_t)d.sm_count) target = (std::uint64_t)d.sm_count;
                    d.grid_size = (std::uint32_t)target;
                }
            }

            if (d.h_result->found) {
                if (!st->found_in_job.exchange(true, std::memory_order_acq_rel)) {
                    std::ostringstream os;
                    os << "{\"type\":\"found\",\"job\":" << local_job_id
                       << ",\"device\":\"" << json_escape(d.name) << "\""
                       << ",\"nonce\":\""  << u64_to_dec(d.h_result->nonce) << "\""
                       << ",\"hash\":\""   << hash_to_hex(d.h_result->hash) << "\""
                       << ",\"hashes\":"   << job_hashes
                       << ",\"hashrate\":" << (std::uint64_t)hashrate_ema
                       << ",\"elapsed_ms\":" << (now - job_started_ms)
                       << "}";
                    emit(os.str());
                }
                have_job = false;
                break;
            }

            if (now - last_emit_ms >= prog_period) {
                last_emit_ms = now;
                std::ostringstream os;
                os << "{\"type\":\"progress\",\"job\":" << local_job_id
                   << ",\"device\":\"" << json_escape(d.name) << "\""
                   << ",\"hashes\":"   << job_hashes
                   << ",\"hashrate\":" << (std::uint64_t)hashrate_ema
                   << ",\"elapsed_ms\":" << (now - job_started_ms)
                   << "}";
                emit(os.str());
            }
        }
    }

    release_device(d);
}

// =============================================================================
// Stdin reader
// =============================================================================

// JOB <inner_hex32> <entropy_hex32> <difficulty_hex32> <job_id>
bool parse_job_line(const std::string& line, Job& job, std::string& err) {
    std::istringstream is(line);
    std::string cmd, inner_s, eps_s, diff_s, id_s;
    is >> cmd >> inner_s >> eps_s >> diff_s >> id_s;
    if (cmd != "JOB" || inner_s.empty() || eps_s.empty() || diff_s.empty() || id_s.empty()) {
        err = "expected: JOB <inner_hex32> <entropy_hex32> <difficulty_hex32> <job_id>";
        return false;
    }
    std::uint8_t ib[32], eb[32], db[32];
    if (!parse_hex32(inner_s, ib)) { err = "inner must be 32-byte hex";    return false; }
    if (!parse_hex32(eps_s,   eb)) { err = "entropy must be 32-byte hex";  return false; }
    if (!parse_hex32(diff_s,  db)) { err = "difficulty must be 32-byte hex"; return false; }
    char* end = nullptr;
    unsigned long long parsed_id = std::strtoull(id_s.c_str(), &end, 10);
    if (end == id_s.c_str() || *end != '\0' || parsed_id == 0ULL) {
        err = "job_id must be a positive decimal u64";
        return false;
    }
    for (int i = 0; i < 4; ++i) job.inner[i]      = load_le64(ib + i * 8);
    for (int i = 0; i < 4; ++i) job.entropy[i]    = load_le64(eb + i * 8);
    for (int i = 0; i < 4; ++i) job.difficulty[i] = load_be64(db + i * 8);
    job.id = static_cast<std::uint64_t>(parsed_id);
    std::random_device rd;
    job.base_nonce = ((std::uint64_t)rd() << 32) ^ (std::uint64_t)rd();
    job.active = true;
    return true;
}

void stdin_reader(SharedState* st) {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (st->exit_requested.load()) break;
        line = trim(line);
        if (line.empty()) continue;
        if (line.rfind("JOB", 0) == 0) {
            Job j; std::string err;
            if (!parse_job_line(line, j, err)) { emit_error(err); continue; }
            {
                std::lock_guard<std::mutex> lk(st->mu);
                st->job = j;
                if (j.id >= st->next_job_id && j.id != UINT64_MAX) st->next_job_id = j.id + 1;
                st->found_in_job.store(false, std::memory_order_release);
            }
            st->cv.notify_all();
        } else if (line == "STOP") {
            {
                std::lock_guard<std::mutex> lk(st->mu);
                st->job.active = false;
                st->job.id = st->next_job_id++;
            }
            st->cv.notify_all();
        } else if (line == "EXIT" || line == "QUIT") {
            st->exit_requested.store(true, std::memory_order_release);
            st->cv.notify_all();
            return;
        } else {
            emit_error("unknown command (expected JOB|STOP|EXIT)");
        }
    }
    st->exit_requested.store(true, std::memory_order_release);
    st->cv.notify_all();
}

// =============================================================================
// Device enumeration
// =============================================================================

bool enumerate_devices(std::vector<DeviceCtx>& devices, std::string& err) {
    int count = 0;
    cudaError_t e = cudaGetDeviceCount(&count);
    if (e != cudaSuccess) {
        std::ostringstream os;
        os << "cudaGetDeviceCount: " << cudaGetErrorString(e)
           << ". Hint: install the NVIDIA driver and CUDA runtime; under WSL2 "
              "ensure the Windows-side NVIDIA driver is current and that "
              "/dev/dxg + /usr/lib/wsl/lib/libcuda.so are present.";
        err = os.str();
        return false;
    }
    if (count == 0) { err = "no CUDA devices found"; return false; }
    for (int i = 0; i < count; ++i) {
        DeviceCtx d;
        d.device_id = i;
        cudaDeviceProp prop{};
        if (cudaGetDeviceProperties(&prop, i) != cudaSuccess) continue;
        d.name        = prop.name;
        d.sm_count    = prop.multiProcessorCount;
        d.max_threads = prop.maxThreadsPerBlock;
        devices.push_back(d);
    }
    if (devices.empty()) { err = "no CUDA devices enumerable"; return false; }
    return true;
}

// =============================================================================
// Main modes
// =============================================================================

int run_common(std::vector<DeviceCtx>& devices, SharedState& st, bool interactive) {
    std::vector<DeviceCtx> initialized;
    initialized.reserve(devices.size());
    for (std::size_t i = 0; i < devices.size(); ++i) {
        devices[i].index         = i;
        devices[i].device_stride = (std::uint64_t)i << 56;
        std::string err;
        if (!init_device(devices[i], err)) { emit_error(err); continue; }
        initialized.push_back(std::move(devices[i]));
    }
    if (initialized.empty()) { emit_error("no CUDA devices initialized"); return 1; }

    // Ready event -- field names match main.rs's DeviceInfo (index/name/cu/wg).
    {
        std::ostringstream os;
        os << "{\"type\":\"ready\",\"devices\":[";
        for (std::size_t i = 0; i < initialized.size(); ++i) {
            if (i) os << ',';
            os << "{\"index\":"  << i
               << ",\"name\":\"" << json_escape(initialized[i].name) << "\""
               << ",\"cu\":"     << initialized[i].sm_count
               << ",\"wg\":"     << initialized[i].block_size
               << ",\"grid\":"   << initialized[i].grid_size
               << ",\"npt\":"    << initialized[i].npt
               << "}";
        }
        os << "]}";
        emit(os.str());
    }

    std::vector<std::thread> workers;
    for (auto& d : initialized) workers.emplace_back(device_worker, std::move(d), &st);

    if (interactive) {
        stdin_reader(&st);
    } else {
        while (!st.exit_requested.load() && !st.found_in_job.load())
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        st.exit_requested.store(true);
        st.cv.notify_all();
    }

    for (auto& w : workers) if (w.joinable()) w.join();
    return 0;
}

int run_once(const std::string& inner_hex,
             const std::string& eps_hex,
             const std::string& diff_hex)
{
    std::vector<DeviceCtx> devices;
    std::string err;
    if (!enumerate_devices(devices, err)) { emit_error(err); return 1; }

    auto wanted = env_csv_indices("MINER_DEVICES");
    if (!wanted.empty()) {
        std::vector<DeviceCtx> filtered;
        for (std::size_t i : wanted)
            if (i < devices.size()) filtered.push_back(std::move(devices[i]));
        devices = std::move(filtered);
    }
    if (devices.empty()) { emit_error("no devices selected"); return 1; }

    std::uint8_t ib[32], eb[32], db[32];
    if (!parse_hex32(inner_hex, ib) || !parse_hex32(eps_hex, eb) || !parse_hex32(diff_hex, db)) {
        emit_error("inner/entropy/difficulty must be 32-byte hex"); return 1;
    }

    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);

    Job j;
    for (int i = 0; i < 4; ++i) j.inner[i]      = load_le64(ib + i * 8);
    for (int i = 0; i < 4; ++i) j.entropy[i]    = load_le64(eb + i * 8);
    for (int i = 0; i < 4; ++i) j.difficulty[i] = load_be64(db + i * 8);
    std::random_device rd;
    j.base_nonce = ((std::uint64_t)rd() << 32) ^ (std::uint64_t)rd();
    j.active = true;
    j.id = 1;
    st.next_job_id = 2;
    st.job = j;

    return run_common(devices, st, false);
}

int run_interactive() {
    std::vector<DeviceCtx> devices;
    std::string err;
    if (!enumerate_devices(devices, err)) { emit_error(err); return 1; }

    auto wanted = env_csv_indices("MINER_DEVICES");
    if (!wanted.empty()) {
        std::vector<DeviceCtx> filtered;
        for (std::size_t i : wanted)
            if (i < devices.size()) filtered.push_back(std::move(devices[i]));
        devices = std::move(filtered);
    }
    if (devices.empty()) { emit_error("no devices selected"); return 1; }

    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);

    return run_common(devices, st, true);
}

} // namespace

// =============================================================================
// Entry point
// =============================================================================

int main(int argc, char** argv) {
    if (argc >= 2 && std::strcmp(argv[1], "--once") == 0) {
        if (argc < 5) {
            std::cerr << "{\"type\":\"error\",\"message\":\"usage: ./miner --once "
                         "<inner_hex32> <entropy_hex32> <difficulty_hex32>\"}\n";
            return 2;
        }
        return run_once(argv[2], argv[3], argv[4]);
    }
    return run_interactive();
}
