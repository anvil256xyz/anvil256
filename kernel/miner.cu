// =============================================================================
// miner.cu — high-performance CUDA GPU miner for Anvil256 Cascade PoW
//
// PoW model (Anvil256.sol::_cascadeHash):
//   mid    = keccak256(abi.encode(inner, nonce))   // 64-byte input
//   result = keccak256(abi.encode(mid,   entropy)) // 64-byte input
//   valid  iff uint256(result) < currentDifficulty
//
// abi.encode(bytes32, uint256) layout (64 bytes, single keccak-256 block):
//   bytes [ 0..32) = bytes32 raw
//   bytes [32..64) = uint256 big-endian
//
// Keccak state lane mapping (little-endian u64) per pass:
//   Pass 1: lane[0..3]=inner, lane[4..6]=0, lane[7]=bswap64(nonce_u64),
//           lane[8]=0x01, lane[16]=0x8000000000000000, rest=0.
//   Pass 2: lane[0..3]=mid (a00..a03 from pass 1), lane[4..7]=entropy,
//           lane[8]=0x01, lane[16]=0x8000000000000000, rest=0.
//
// =============================================================================
// Tuning changes vs. previous revision
// =============================================================================
//   Kernel:
//     • __launch_bounds__(128, 8): raised hint from 4→8 blk/SM — on sm_89
//       (RTX 4060 Ti, 34 SM) this targets 34×8×128 = 34816 resident threads,
//       keeping pipeline latency hidden without spilling to local memory.
//     • #pragma unroll removed from the per-thread nonce loop — compilers
//       running at -O3 do better without the forced unroll on a variable-count
//       loop; loop overhead is negligible vs two full Keccak-f[1600] calls.
//     • Round macro is otherwise unchanged (auditable vs cpu_cascade.hpp).
//   Host auto-tune (device_worker):
//     • EMA_ALPHA raised 0.30→0.40 for faster convergence on rate changes.
//     • Grid grows up to SM_count * 2048 blocks (was * 1024); on sm_89 that
//       is 69632 blocks × 128 threads × npt nonces per launch — keeps the GPU
//       saturated during difficulty ramps without a manual MINER_GRID override.
//     • Grid grow cap per tick: 8× instead of 4× (faster cold-start ramp).
//     • NPT grow cap per tick: 4× instead of 2× (previously limited ramp to
//       NPT=4096 after 12 ticks; now reaches NPT=4096 in 6 ticks).
//     • Shrink triggered at >2× target (was 4×) to prevent batch overshoot.
//     • MIN_TARGET_MS floor lowered to 10.0 ms (was 25.0); useful for very
//       fast GPUs (RTX 5090, H100) and benchmark / --once mode.
//     • Exit path: spin-sleep reduced to 20 ms so EXIT ACK is faster.
//   Struct Result:
//     • Padded to 64 bytes with explicit __align__(64) so pinned DtoH copy
//       always lands on a single cache line (PCIE / NVLink read coalescing).
// =============================================================================
// Build
// =============================================================================
// Linux / WSL2 (CUDA toolkit 12.x):
//   nvcc -O3 -std=c++17 -Xcompiler -pthread \
//        -arch=sm_89 miner.cu -o miner
//
// Multi-arch fat binary (Turing / Ampere / Ada / Hopper / Blackwell):
//   nvcc -O3 -std=c++17 -Xcompiler -pthread \
//        -gencode arch=compute_75,code=sm_75   \
//        -gencode arch=compute_80,code=sm_80   \
//        -gencode arch=compute_86,code=sm_86   \
//        -gencode arch=compute_89,code=sm_89   \
//        -gencode arch=compute_90,code=sm_90   \
//        -gencode arch=compute_100,code=sm_100 \
//        -gencode arch=compute_120,code=sm_120 \
//        -gencode arch=compute_120,code=compute_120 \
//        miner.cu -o miner
// =============================================================================
// Env vars
// =============================================================================
//   MINER_DEVICES=0,1            comma-list of CUDA device indices to use
//   MINER_BLOCK=128              threads per block (default 128, must be ≤256)
//   MINER_GRID=0                 blocks per launch (0 = auto: SM_count × 128)
//   MINER_NPT=128                nonces per thread per launch
//   MINER_TARGET_BATCH_MS=250    auto-tune target launch duration (ms)
//   MINER_PROGRESS_MS=750        progress-event emit period (ms)
// =============================================================================

#include <cuda_runtime.h>
#include "host_common.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// =============================================================================
// Constant memory (broadcast-cached per SM; one copy per CUDA device)
// =============================================================================
// d_INNER[i] = LE u64 of inner   bytes [8i .. 8i+8)
// d_EPS[i]   = LE u64 of entropy bytes [8i .. 8i+8)
// d_DIFF[i]  = BE u64 of difficulty ([0]=most-significant)
__constant__ std::uint64_t d_INNER[4];
__constant__ std::uint64_t d_EPS[4];
__constant__ std::uint64_t d_DIFF[4];

// =============================================================================
// Result struct — 64-byte aligned for single-cache-line DtoH copy
// =============================================================================
struct alignas(64) Result {
    unsigned int  found;           // atomicCAS guard
    unsigned int  _pad0;
    std::uint64_t nonce;
    std::uint64_t hash[4];         // BE word order: hash[0] = MSB
    std::uint64_t _pad1[2];        // pad to 64 bytes
};
static_assert(sizeof(Result) == 64, "Result must be exactly 64 bytes");

// =============================================================================
// Device helpers
// =============================================================================

__device__ __forceinline__ std::uint64_t rotl64(std::uint64_t x, int n) {
    // ptxas → SHF.L.WRAP.B32 pair (1-cycle 64-bit funnel-shift on sm_70+).
    return (x << n) | (x >> (64 - n));
}

__device__ __forceinline__ std::uint64_t bswap64(std::uint64_t v) {
    // 2× PRMT instructions for a full 64-bit byte-reverse.
    std::uint32_t hi = static_cast<std::uint32_t>(v >> 32);
    std::uint32_t lo = static_cast<std::uint32_t>(v);
    return (static_cast<std::uint64_t>(__byte_perm(lo, 0u, 0x0123u)) << 32)
         |  static_cast<std::uint64_t>(__byte_perm(hi, 0u, 0x0123u));
}

// =============================================================================
// Keccak-f[1600] round macro
//
// `rc` is a 64-bit literal → ptxas emits XOR.B64 with an immediate operand
// (no constant-memory load for the round constant).
// =============================================================================
#define KECCAK_R(rc)                                                             \
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

#define KECCAK_24_ROUNDS                                                          \
    KECCAK_R(0x0000000000000001ULL); KECCAK_R(0x0000000000008082ULL);            \
    KECCAK_R(0x800000000000808aULL); KECCAK_R(0x8000000080008000ULL);            \
    KECCAK_R(0x000000000000808bULL); KECCAK_R(0x0000000080000001ULL);            \
    KECCAK_R(0x8000000080008081ULL); KECCAK_R(0x8000000000008009ULL);            \
    KECCAK_R(0x000000000000008aULL); KECCAK_R(0x0000000000000088ULL);            \
    KECCAK_R(0x0000000080008009ULL); KECCAK_R(0x000000008000000aULL);            \
    KECCAK_R(0x000000008000808bULL); KECCAK_R(0x800000000000008bULL);            \
    KECCAK_R(0x8000000000008089ULL); KECCAK_R(0x8000000000008003ULL);            \
    KECCAK_R(0x8000000000008002ULL); KECCAK_R(0x8000000000000080ULL);            \
    KECCAK_R(0x000000000000800aULL); KECCAK_R(0x800000008000000aULL);            \
    KECCAK_R(0x8000000080008081ULL); KECCAK_R(0x8000000000008080ULL);            \
    KECCAK_R(0x0000000080000001ULL); KECCAK_R(0x8000000080008008ULL)

// =============================================================================
// mine_kernel
//
// __launch_bounds__(128, 8):
//   Max 128 threads/block; hint ≥8 blocks/SM.
//   RTX 4060 Ti (sm_89, 34 SM): 34 × 8 × 128 = 34 816 resident threads = 272
//   warps/SM, keeping the warp scheduler busy while memory latency hides.
// =============================================================================
__global__ __launch_bounds__(128, 8)
void mine_kernel(
    const std::uint64_t  base_nonce,
    const std::uint32_t  nonces_per_thread,
    Result* __restrict__ result)
{
    const std::uint64_t tid   = static_cast<std::uint64_t>(blockIdx.x)
                              * static_cast<std::uint64_t>(blockDim.x)
                              + static_cast<std::uint64_t>(threadIdx.x);
    const std::uint64_t start = base_nonce + tid * static_cast<std::uint64_t>(nonces_per_thread);

    // Cache constant-memory reads into registers (avoids repeated broadcasts).
    const std::uint64_t i0=d_INNER[0], i1=d_INNER[1], i2=d_INNER[2], i3=d_INNER[3];
    const std::uint64_t e0=d_EPS[0],   e1=d_EPS[1],   e2=d_EPS[2],   e3=d_EPS[3];
    const std::uint64_t df0=d_DIFF[0], df1=d_DIFF[1], df2=d_DIFF[2], df3=d_DIFF[3];

    for (std::uint32_t k = 0; k < nonces_per_thread; ++k) {
        const std::uint64_t nonce = start + static_cast<std::uint64_t>(k);

        // ----- Pass 1: mid = keccak256(abi.encode(inner, nonce)) ------------
        std::uint64_t a00=i0,   a01=i1,   a02=i2,   a03=i3;
        std::uint64_t a04=0ULL, a05=0ULL, a06=0ULL;
        std::uint64_t a07=bswap64(nonce);
        std::uint64_t a08=1ULL;
        std::uint64_t a09=0ULL, a10=0ULL, a11=0ULL, a12=0ULL;
        std::uint64_t a13=0ULL, a14=0ULL, a15=0ULL;
        std::uint64_t a16=0x8000000000000000ULL;
        std::uint64_t a17=0ULL, a18=0ULL, a19=0ULL;
        std::uint64_t a20=0ULL, a21=0ULL, a22=0ULL, a23=0ULL, a24=0ULL;

        KECCAK_24_ROUNDS;

        // ----- Pass 2: result = keccak256(abi.encode(mid, entropy)) ---------
        // a00..a03 already hold mid; reload lanes 4-7 with entropy.
        a04=e0; a05=e1; a06=e2; a07=e3;
        a08=1ULL;
        a09=0ULL; a10=0ULL; a11=0ULL; a12=0ULL;
        a13=0ULL; a14=0ULL; a15=0ULL;
        a16=0x8000000000000000ULL;
        a17=0ULL; a18=0ULL; a19=0ULL;
        a20=0ULL; a21=0ULL; a22=0ULL; a23=0ULL; a24=0ULL;

        KECCAK_24_ROUNDS;

        // ----- uint256 BE compare with fast-reject short-circuit ------------
        const std::uint64_t h0 = bswap64(a00);
        if (h0 > df0) continue;
        if (h0 < df0) {
            // Definite win — first 8 bytes alone beat difficulty.
            if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                result->nonce   = nonce;
                result->hash[0] = h0;
                result->hash[1] = bswap64(a01);
                result->hash[2] = bswap64(a02);
                result->hash[3] = bswap64(a03);
            }
            return;
        }
        // h0 == df0 — need to inspect further words.
        const std::uint64_t h1 = bswap64(a01);
        if (h1 > df1) continue;
        if (h1 < df1) {
            if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                result->nonce   = nonce;
                result->hash[0] = h0; result->hash[1] = h1;
                result->hash[2] = bswap64(a02);
                result->hash[3] = bswap64(a03);
            }
            return;
        }
        const std::uint64_t h2 = bswap64(a02);
        if (h2 > df2) continue;
        if (h2 < df2) {
            if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                result->nonce   = nonce;
                result->hash[0] = h0; result->hash[1] = h1; result->hash[2] = h2;
                result->hash[3] = bswap64(a03);
            }
            return;
        }
        // h2 == df2
        const std::uint64_t h3 = bswap64(a03);
        if (h3 >= df3) continue;
        if (atomicCAS(&result->found, 0u, 1u) == 0u) {
            result->nonce   = nonce;
            result->hash[0] = h0; result->hash[1] = h1;
            result->hash[2] = h2; result->hash[3] = h3;
        }
        return;
    }
}

#undef KECCAK_R
#undef KECCAK_24_ROUNDS

// =============================================================================
// Host helpers (all in anonymous namespace)
// =============================================================================
namespace {

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------
constexpr std::uint32_t DEFAULT_BLOCK      = 128;
constexpr std::uint32_t DEFAULT_NPT        = 128;
constexpr std::uint32_t MIN_NPT            = 1;
constexpr std::uint32_t MAX_NPT            = 4096;
constexpr std::uint32_t MAX_BLOCK          = 256;
constexpr std::uint64_t DEFAULT_PROG_MS    = 750;
constexpr std::uint64_t DEVICE_NONCE_WIN   = 1ULL << 56;
constexpr double        DEFAULT_TGT_MS     = 250.0;
constexpr double        EMA_ALPHA          = 0.40;  // raised for faster tracking

// Max grid: SM_count * 2048 (was * 1024) — keeps large GPUs saturated.
constexpr std::uint32_t GRID_MULT_MAX      = 2048;

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
std::vector<std::size_t> env_csv_indices(const char* name) {
    std::vector<std::size_t> out;
    const char* v = std::getenv(name);
    if (!v || !*v) return out;
    std::string s = v;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        item = anvil256::trim(item);
        if (item.empty()) continue;
        char* end = nullptr;
        unsigned long idx = std::strtoul(item.c_str(), &end, 10);
        if (end != item.c_str()) out.push_back(static_cast<std::size_t>(idx));
    }
    return out;
}

bool cuda_check(cudaError_t e, const char* where, std::string& msg) {
    if (e == cudaSuccess) return true;
    std::ostringstream os;
    os << where << ": " << cudaGetErrorString(e) << " (" << static_cast<int>(e) << ")";
    msg = os.str();
    return false;
}

// ---------------------------------------------------------------------------
// Shared state types
// ---------------------------------------------------------------------------
using anvil256::Job;
using anvil256::SharedState;

SharedState* g_state_ptr = nullptr;

void handle_signal(int) {
    if (g_state_ptr) {
        g_state_ptr->exit_requested.store(true, std::memory_order_release);
        g_state_ptr->cv.notify_all();
    }
}

// ---------------------------------------------------------------------------
// Per-device CUDA context
// ---------------------------------------------------------------------------
struct DeviceCtx {
    int           device_id     = 0;
    std::size_t   index         = 0;
    std::string   name;
    int           sm_count      = 0;
    int           max_threads   = 1024;
    std::uint32_t block_size    = DEFAULT_BLOCK;
    std::uint32_t grid_size     = 0;
    std::uint32_t npt           = DEFAULT_NPT;
    std::uint64_t device_stride = 0;
    std::uint64_t window_used   = 0;
    double        target_ms     = DEFAULT_TGT_MS;

    cudaStream_t  stream   = nullptr;
    Result*       d_result = nullptr;   // device buffer
    Result*       h_result = nullptr;   // pinned host buffer (64-byte aligned)
};

bool init_device(DeviceCtx& d, std::string& err) {
    if (!cuda_check(cudaSetDevice(d.device_id), "cudaSetDevice", err)) return false;

    cudaDeviceProp prop{};
    if (!cuda_check(cudaGetDeviceProperties(&prop, d.device_id),
                    "cudaGetDeviceProperties", err)) return false;
    d.name        = prop.name;
    d.sm_count    = prop.multiProcessorCount;
    d.max_threads = prop.maxThreadsPerBlock;

    // ---- block size --------------------------------------------------------
    std::uint32_t blk = static_cast<std::uint32_t>(
        anvil256::env_u64("MINER_BLOCK", DEFAULT_BLOCK));
    blk = std::max(32u, std::min(blk, static_cast<std::uint32_t>(
          std::min(MAX_BLOCK, static_cast<std::uint32_t>(d.max_threads)))));
    blk = (blk / 32) * 32;   // round down to warp boundary
    if (blk == 0) blk = 32;
    d.block_size = blk;

    // ---- NPT ---------------------------------------------------------------
    std::uint32_t npt = static_cast<std::uint32_t>(
        anvil256::env_u64("MINER_NPT", DEFAULT_NPT));
    d.npt = std::max(MIN_NPT, std::min(npt, MAX_NPT));

    // ---- grid size ---------------------------------------------------------
    std::uint64_t env_grid = anvil256::env_u64("MINER_GRID", 0);
    if (env_grid == 0) {
        // Auto: SM_count × 128 blocks (8 waves × 16 blocks/SM).
        // This matches __launch_bounds__(128, 8) hint on sm_89.
        d.grid_size = std::max(64u, static_cast<std::uint32_t>(d.sm_count * 128));
    } else {
        d.grid_size = static_cast<std::uint32_t>(env_grid);
    }

    // ---- target batch duration ---------------------------------------------
    d.target_ms = anvil256::env_f64("MINER_TARGET_BATCH_MS", DEFAULT_TGT_MS);
    d.target_ms = std::max(10.0, std::min(d.target_ms, 2000.0));

    // ---- CUDA resource allocation -----------------------------------------
    if (!cuda_check(cudaStreamCreateWithFlags(&d.stream, cudaStreamNonBlocking),
                    "cudaStreamCreate", err)) return false;
    if (!cuda_check(cudaMalloc(&d.d_result, sizeof(Result)),
                    "cudaMalloc(d_result)", err)) return false;
    if (!cuda_check(cudaHostAlloc(reinterpret_cast<void**>(&d.h_result),
                                  sizeof(Result), cudaHostAllocDefault),
                    "cudaHostAlloc(h_result)", err)) return false;
    return true;
}

void release_device(DeviceCtx& d) {
    cudaSetDevice(d.device_id);
    if (d.d_result) { cudaFree(d.d_result);       d.d_result = nullptr; }
    if (d.h_result) { cudaFreeHost(d.h_result);   d.h_result = nullptr; }
    if (d.stream)   { cudaStreamDestroy(d.stream); d.stream   = nullptr; }
}

// ---------------------------------------------------------------------------
// Device worker thread
// ---------------------------------------------------------------------------
void device_worker(DeviceCtx d, SharedState* st) {
    cudaSetDevice(d.device_id);

    std::uint64_t local_job_id  = 0;
    std::uint64_t job_started   = 0;
    std::uint64_t job_hashes    = 0;
    double        hashrate_ema  = 0.0;
    std::uint64_t last_emit_ms  = 0;
    std::uint64_t base_nonce    = 0;
    bool          have_job      = false;

    const std::uint64_t prog_period =
        anvil256::env_u64("MINER_PROGRESS_MS", DEFAULT_PROG_MS);
    const std::uint32_t grid_max =
        static_cast<std::uint32_t>(d.sm_count) * GRID_MULT_MAX;

    while (!st->exit_requested.load(std::memory_order_acquire)) {

        std::uint64_t inner[4]={}, eps[4]={}, diff[4]={};

        // ---- wait for active job (50 ms max for bounded EXIT latency) ------
        {
            std::unique_lock<std::mutex> lk(st->mu);
            st->cv.wait_for(lk, std::chrono::milliseconds(50), [&] {
                return st->exit_requested.load() ||
                       (st->job.active && st->job.id != local_job_id);
            });
            if (st->exit_requested.load()) break;
            if (!st->job.active || st->job.id == local_job_id) continue;

            const Job& j = st->job;
            local_job_id = j.id;
            for (int i = 0; i < 4; ++i) inner[i] = j.inner[i];
            for (int i = 0; i < 4; ++i) eps[i]   = j.entropy[i];
            for (int i = 0; i < 4; ++i) diff[i]  = j.difficulty[i];
            base_nonce     = j.base_nonce + d.device_stride;
            d.window_used  = 0;
            have_job       = true;
            job_started    = anvil256::now_ms();
            job_hashes     = 0;
            hashrate_ema   = 0.0;
            last_emit_ms   = job_started;
        }

        // ---- push job into constant memory ---------------------------------
        {
            std::string err;
            auto sym = [&](auto& sym_ref, const void* src, std::size_t sz) {
                return cuda_check(cudaMemcpyToSymbolAsync(
                    sym_ref, src, sz, 0, cudaMemcpyHostToDevice, d.stream), "", err);
            };
            if (!sym(d_INNER, inner, sizeof(inner)) ||
                !sym(d_EPS,   eps,   sizeof(eps))   ||
                !sym(d_DIFF,  diff,  sizeof(diff)))
            {
                anvil256::emit_error("cudaMemcpyToSymbol: " + err);
                have_job = false;
                continue;
            }
        }

        // ---- mining loop ---------------------------------------------------
        while (have_job) {
            if (st->exit_requested.load(std::memory_order_acquire)) { have_job=false; break; }
            if (st->found_in_job.load(std::memory_order_acquire))   { have_job=false; break; }
            {
                std::lock_guard<std::mutex> lk(st->mu);
                if (st->job.id != local_job_id || !st->job.active) { have_job=false; break; }
            }

            const std::uint64_t did =
                static_cast<std::uint64_t>(d.grid_size) *
                static_cast<std::uint64_t>(d.block_size) *
                static_cast<std::uint64_t>(d.npt);

            if (did == 0 || d.window_used > DEVICE_NONCE_WIN - did) {
                std::ostringstream os;
                os << "device nonce window exhausted for " << d.name
                   << "; restart job to prevent cross-device nonce overlap";
                anvil256::emit_error(os.str());
                have_job = false;
                break;
            }

            std::string err;

            // Reset result buffer, launch kernel, copy result back.
            if (!cuda_check(cudaMemsetAsync(d.d_result, 0, sizeof(Result), d.stream),
                            "cudaMemsetAsync", err))
            { anvil256::emit_error(err); have_job=false; break; }

            const std::uint64_t batch_started = anvil256::now_ms();

            mine_kernel<<<d.grid_size, d.block_size, 0, d.stream>>>(
                base_nonce, d.npt, d.d_result);

            if (!cuda_check(cudaGetLastError(), "kernel launch", err))
            { anvil256::emit_error(err); have_job=false; break; }

            if (!cuda_check(cudaMemcpyAsync(d.h_result, d.d_result, sizeof(Result),
                                            cudaMemcpyDeviceToHost, d.stream),
                            "cudaMemcpyAsync", err))
            { anvil256::emit_error(err); have_job=false; break; }

            if (!cuda_check(cudaStreamSynchronize(d.stream),
                            "cudaStreamSynchronize", err))
            { anvil256::emit_error(err); have_job=false; break; }

            const std::uint64_t now = anvil256::now_ms();
            std::uint64_t batch_ms  = now - batch_started;
            if (batch_ms == 0) batch_ms = 1;

            base_nonce    += did;
            d.window_used += did;
            job_hashes    += did;

            const double rate = static_cast<double>(did) * 1000.0
                              / static_cast<double>(batch_ms);
            hashrate_ema = (hashrate_ema == 0.0)
                ? rate
                : (EMA_ALPHA * rate + (1.0 - EMA_ALPHA) * hashrate_ema);

            // ---- adaptive grid + NPT auto-tune ----------------------------
            // Grow at <50% target; shrink at >200% target (2× instead of 4×).
            const double tgt = d.target_ms;
            if (static_cast<double>(batch_ms) < tgt * 0.5) {
                const double scale = tgt / static_cast<double>(batch_ms);
                if (d.grid_size < grid_max) {
                    // Prefer growing grid first (better occupancy).
                    std::uint64_t g = static_cast<std::uint64_t>(
                        static_cast<double>(d.grid_size) * scale);
                    g = std::min(g, static_cast<std::uint64_t>(d.grid_size) * 8ULL);
                    g = std::min(g, static_cast<std::uint64_t>(grid_max));
                    d.grid_size = static_cast<std::uint32_t>(std::max<std::uint64_t>(1, g));
                } else if (d.npt < MAX_NPT) {
                    std::uint64_t n = static_cast<std::uint64_t>(
                        static_cast<double>(d.npt) * scale);
                    n = std::min(n, static_cast<std::uint64_t>(d.npt) * 4ULL);
                    n = std::min(n, static_cast<std::uint64_t>(MAX_NPT));
                    d.npt = static_cast<std::uint32_t>(std::max<std::uint64_t>(MIN_NPT, n));
                }
            } else if (static_cast<double>(batch_ms) > tgt * 2.0) {
                // Shrink NPT first; then grid if NPT already at minimum.
                if (d.npt > MIN_NPT) {
                    std::uint64_t n = static_cast<std::uint64_t>(
                        static_cast<double>(d.npt) * tgt / static_cast<double>(batch_ms));
                    d.npt = static_cast<std::uint32_t>(
                        std::max<std::uint64_t>(MIN_NPT, std::min(n, static_cast<std::uint64_t>(MAX_NPT))));
                } else if (d.grid_size > static_cast<std::uint32_t>(d.sm_count)) {
                    std::uint64_t g = static_cast<std::uint64_t>(
                        static_cast<double>(d.grid_size) * tgt / static_cast<double>(batch_ms));
                    d.grid_size = static_cast<std::uint32_t>(
                        std::max<std::uint64_t>(static_cast<std::uint64_t>(d.sm_count), g));
                }
            }

            // ---- found? emit event ----------------------------------------
            if (d.h_result->found) {
                if (!st->found_in_job.exchange(true, std::memory_order_acq_rel)) {
                    std::ostringstream os;
                    os << "{\"type\":\"found\",\"job\":" << local_job_id
                       << ",\"device\":\"" << anvil256::json_escape(d.name) << "\""
                       << ",\"nonce\":\""  << anvil256::u64_to_dec(d.h_result->nonce) << "\""
                       << ",\"hash\":\""   << anvil256::hash_to_hex(d.h_result->hash) << "\""
                       << ",\"hashes\":"   << job_hashes
                       << ",\"hashrate\":" << static_cast<std::uint64_t>(hashrate_ema)
                       << ",\"elapsed_ms\":" << (now - job_started)
                       << "}";
                    anvil256::emit(os.str());
                }
                have_job = false;
                break;
            }

            // ---- periodic progress -----------------------------------------
            if (now - last_emit_ms >= prog_period) {
                last_emit_ms = now;
                std::ostringstream os;
                os << "{\"type\":\"progress\",\"job\":" << local_job_id
                   << ",\"device\":\"" << anvil256::json_escape(d.name) << "\""
                   << ",\"hashes\":"   << job_hashes
                   << ",\"hashrate\":" << static_cast<std::uint64_t>(hashrate_ema)
                   << ",\"elapsed_ms\":" << (now - job_started)
                   << "}";
                anvil256::emit(os.str());
            }
        } // mining loop

        release_device(d);
    } // outer while

    // Cleanup if we exit the outer loop without calling release_device.
    release_device(d);
}

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------
bool enumerate_devices(std::vector<DeviceCtx>& devices, std::string& err) {
    int count = 0;
    cudaError_t e = cudaGetDeviceCount(&count);
    if (e != cudaSuccess) {
        std::ostringstream os;
        os << "cudaGetDeviceCount: " << cudaGetErrorString(e)
           << ". Hint: install the NVIDIA driver + CUDA runtime; under WSL2 "
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

// ---------------------------------------------------------------------------
// Filter devices by MINER_DEVICES env var
// ---------------------------------------------------------------------------
void filter_devices(std::vector<DeviceCtx>& devices) {
    auto wanted = env_csv_indices("MINER_DEVICES");
    if (wanted.empty()) return;
    std::vector<DeviceCtx> filtered;
    for (std::size_t i : wanted)
        if (i < devices.size()) filtered.push_back(std::move(devices[i]));
    devices = std::move(filtered);
}

// ---------------------------------------------------------------------------
// Common run path (interactive + one-shot share this)
// ---------------------------------------------------------------------------
int run_common(std::vector<DeviceCtx>& devices, SharedState& st, bool interactive) {
    // Initialise each device; drop ones that fail.
    std::vector<DeviceCtx> initialized;
    initialized.reserve(devices.size());
    for (std::size_t i = 0; i < devices.size(); ++i) {
        devices[i].index         = i;
        devices[i].device_stride = static_cast<std::uint64_t>(i) << 56;
        std::string err;
        if (!init_device(devices[i], err)) { anvil256::emit_error(err); continue; }
        initialized.push_back(std::move(devices[i]));
    }
    if (initialized.empty()) {
        anvil256::emit_error("no CUDA devices initialized");
        return 1;
    }

    // Ready event.
    {
        std::ostringstream os;
        os << "{\"type\":\"ready\",\"devices\":[";
        for (std::size_t i = 0; i < initialized.size(); ++i) {
            if (i) os << ',';
            os << "{\"index\":"  << i
               << ",\"name\":\"" << anvil256::json_escape(initialized[i].name) << "\""
               << ",\"cu\":"     << initialized[i].sm_count
               << ",\"wg\":"     << initialized[i].block_size
               << ",\"grid\":"   << initialized[i].grid_size
               << ",\"npt\":"    << initialized[i].npt
               << "}";
        }
        os << "]}";
        anvil256::emit(os.str());
    }

    std::vector<std::thread> workers;
    workers.reserve(initialized.size());
    for (auto& d : initialized)
        workers.emplace_back(device_worker, std::move(d), &st);

    if (interactive) {
        anvil256::stdin_reader(&st);
    } else {
        while (!st.exit_requested.load(std::memory_order_acquire) &&
               !st.found_in_job.load(std::memory_order_acquire))
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        st.exit_requested.store(true, std::memory_order_release);
        st.cv.notify_all();
    }

    for (auto& w : workers) if (w.joinable()) w.join();
    return 0;
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------
int run_interactive() {
    std::vector<DeviceCtx> devices;
    std::string err;
    if (!enumerate_devices(devices, err)) { anvil256::emit_error(err); return 1; }
    filter_devices(devices);
    if (devices.empty()) { anvil256::emit_error("no devices selected"); return 1; }

    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);
    return run_common(devices, st, true);
}

int run_once(const std::string& inner_hex,
             const std::string& eps_hex,
             const std::string& diff_hex)
{
    std::vector<DeviceCtx> devices;
    std::string err;
    if (!enumerate_devices(devices, err)) { anvil256::emit_error(err); return 1; }
    filter_devices(devices);
    if (devices.empty()) { anvil256::emit_error("no devices selected"); return 1; }

    std::uint8_t ib[32], eb[32], db[32];
    if (!anvil256::parse_hex32(inner_hex, ib) ||
        !anvil256::parse_hex32(eps_hex,   eb) ||
        !anvil256::parse_hex32(diff_hex,  db))
    {
        anvil256::emit_error("inner/entropy/difficulty must be 32-byte hex");
        return 1;
    }

    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);

    Job j;
    for (int i = 0; i < 4; ++i) j.inner[i]      = anvil256::load_le64(ib + i * 8);
    for (int i = 0; i < 4; ++i) j.entropy[i]    = anvil256::load_le64(eb + i * 8);
    for (int i = 0; i < 4; ++i) j.difficulty[i] = anvil256::load_be64(db + i * 8);
    anvil256::fill_random_base_nonce(j);
    j.active     = true;
    j.id         = 1;
    st.next_job_id = 2;
    st.job         = j;

    return run_common(devices, st, false);
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
