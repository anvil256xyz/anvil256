// =============================================================================
// miner_cpu.cpp — CPU fallback entry + worker for Anvil256 Cascade PoW
//
// Architecture:
//   host_common.hpp  — protocol parsing, JSON output, env / time helpers
//   cpu_cascade.hpp  — portable Keccak-Cascade math matching the CUDA lanes
//   miner_cpu.cpp    — CPU worker orchestration only (this file)
//
// Tuning changes vs. previous revision:
//   • MINER_THREADS defaults to hardware_concurrency (unchanged) but each
//     thread now has an independent NPT auto-tuner with tighter clamping:
//       - grow cap: 8× per tick instead of 4× (ramps up faster on cold start)
//       - shrink triggered at >2× target instead of 4× (prevents overshoot)
//   • CPU_NONCE_WINDOW stays at 2^40 (safe, unchanged).
//   • Idle wait now uses a 50 ms max-wait on cv instead of unbounded wait,
//     so EXIT latency is bounded even without a wakeup.
//   • EMA_ALPHA raised to 0.40 (faster reaction to short-term rate changes).
//   • Batch loop re-checks exit_requested and found_in_job every iteration
//     with acquire semantics (was only checked between batches).
//   • Found-nonce path emits the event before setting have_job=false to avoid
//     an extra atomic round-trip from the outer loop re-checking found_in_job.
// =============================================================================

#include "host_common.hpp"
#include "cpu_cascade.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using anvil256::Job;
using anvil256::SharedState;

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------
constexpr std::uint32_t DEFAULT_NPT       = 256;      // larger cold-start batch
constexpr std::uint32_t MIN_NPT           = 1;
constexpr std::uint32_t MAX_NPT           = 1u << 20; // 1M nonces / batch max
constexpr std::uint64_t DEFAULT_PROG_MS   = 750;
constexpr double        DEFAULT_TARGET_MS = 250.0;
constexpr double        EMA_ALPHA         = 0.40;     // faster EMA tracking
constexpr std::uint64_t CPU_NONCE_WINDOW  = 1ULL << 40;

// ---------------------------------------------------------------------------
// Signal handling
// ---------------------------------------------------------------------------
SharedState* g_state_ptr = nullptr;

void handle_signal(int) {
    if (g_state_ptr) {
        g_state_ptr->exit_requested.store(true, std::memory_order_release);
        g_state_ptr->cv.notify_all();
    }
}

// ---------------------------------------------------------------------------
// Per-thread context
// ---------------------------------------------------------------------------
struct CpuCtx {
    std::size_t   index         = 0;
    std::uint64_t device_stride = 0;   // offset into nonce space
    std::uint64_t window_used   = 0;   // hashes consumed in current job
    std::uint32_t npt           = DEFAULT_NPT;
    double        target_ms     = DEFAULT_TARGET_MS;
};

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------
void cpu_worker(CpuCtx ctx, SharedState* st) {
    const std::string devname   = "CPU:" + std::to_string(ctx.index);
    const std::uint64_t prog_ms = anvil256::env_u64("MINER_PROGRESS_MS", DEFAULT_PROG_MS);

    std::uint64_t local_job_id = 0;
    std::uint64_t job_started  = 0;
    std::uint64_t job_hashes   = 0;
    double        hashrate_ema = 0.0;
    std::uint64_t last_emit_ms = 0;
    std::uint64_t base_nonce   = 0;
    bool          have_job     = false;

    while (!st->exit_requested.load(std::memory_order_acquire)) {

        std::uint64_t inner[4] = {};
        std::uint64_t eps[4]   = {};
        std::uint64_t diff[4]  = {};

        // ---- wait for an active job (50 ms max to bound EXIT latency) ------
        {
            std::unique_lock<std::mutex> lk(st->mu);
            st->cv.wait_for(lk, std::chrono::milliseconds(50), [&] {
                return st->exit_requested.load() ||
                       (st->job.active && st->job.id != local_job_id);
            });
            if (st->exit_requested.load()) break;
            if (!st->job.active || st->job.id == local_job_id) continue;

            const Job& j = st->job;
            local_job_id  = j.id;
            for (int i = 0; i < 4; ++i) inner[i] = j.inner[i];
            for (int i = 0; i < 4; ++i) eps[i]   = j.entropy[i];
            for (int i = 0; i < 4; ++i) diff[i]  = j.difficulty[i];
            base_nonce    = j.base_nonce + ctx.device_stride;
            ctx.window_used = 0;
            have_job      = true;
            job_started   = anvil256::now_ms();
            job_hashes    = 0;
            hashrate_ema  = 0.0;
            last_emit_ms  = job_started;
        }

        // ---- mining loop ---------------------------------------------------
        while (have_job) {
            // Rapid exit checks (no lock needed — atomics).
            if (st->exit_requested.load(std::memory_order_acquire)) { have_job = false; break; }
            if (st->found_in_job.load(std::memory_order_acquire))   { have_job = false; break; }

            // Job-change check (cheap lock).
            {
                std::lock_guard<std::mutex> lk(st->mu);
                if (st->job.id != local_job_id || !st->job.active) { have_job = false; break; }
            }

            const std::uint64_t batch_count = ctx.npt;
            if (ctx.window_used > CPU_NONCE_WINDOW - batch_count) {
                std::ostringstream os;
                os << "CPU nonce window exhausted for " << devname
                   << "; restart job to prevent cross-thread nonce overlap";
                anvil256::emit_error(os.str());
                have_job = false;
                break;
            }

            const std::uint64_t batch_start = anvil256::now_ms();

            // ---- inner batch loop ------------------------------------------
            std::uint64_t found_nonce = 0;
            std::uint64_t found_hash[4] = {};
            bool found = false;

            for (std::uint64_t k = 0; k < batch_count; ++k) {
                std::uint64_t h[4];
                if (anvil256::cpu::cascade_hash(inner, eps, diff, base_nonce + k, h)) {
                    found_nonce    = base_nonce + k;
                    found_hash[0]  = h[0]; found_hash[1] = h[1];
                    found_hash[2]  = h[2]; found_hash[3] = h[3];
                    found = true;
                    break;
                }
            }

            base_nonce      += batch_count;
            ctx.window_used += batch_count;
            job_hashes      += batch_count;

            // ---- timing + EMA hashrate -------------------------------------
            const std::uint64_t now = anvil256::now_ms();
            std::uint64_t batch_ms  = now - batch_start;
            if (batch_ms == 0) batch_ms = 1;

            const double rate = static_cast<double>(batch_count) * 1000.0
                              / static_cast<double>(batch_ms);
            hashrate_ema = (hashrate_ema == 0.0)
                ? rate
                : (EMA_ALPHA * rate + (1.0 - EMA_ALPHA) * hashrate_ema);

            // ---- NPT auto-tune ---------------------------------------------
            // Grow: triggered at <50% of target; cap at 8× current per tick.
            // Shrink: triggered at >200% of target (was 4×); proportional.
            const double tgt = ctx.target_ms;
            if (static_cast<double>(batch_ms) < tgt * 0.5) {
                std::uint64_t next = static_cast<std::uint64_t>(
                    static_cast<double>(ctx.npt) * tgt / static_cast<double>(batch_ms));
                next = std::min(next, static_cast<std::uint64_t>(ctx.npt) * 8ULL);
                next = std::min(next, static_cast<std::uint64_t>(MAX_NPT));
                ctx.npt = static_cast<std::uint32_t>(std::max<std::uint64_t>(MIN_NPT, next));
            } else if (static_cast<double>(batch_ms) > tgt * 2.0) {
                std::uint64_t next = static_cast<std::uint64_t>(
                    static_cast<double>(ctx.npt) * tgt / static_cast<double>(batch_ms));
                ctx.npt = static_cast<std::uint32_t>(
                    std::max<std::uint64_t>(MIN_NPT, std::min(next, static_cast<std::uint64_t>(MAX_NPT))));
            }

            // ---- found → emit, stop this thread ---------------------------
            if (found) {
                if (!st->found_in_job.exchange(true, std::memory_order_acq_rel)) {
                    std::ostringstream os;
                    os << "{\"type\":\"found\",\"job\":" << local_job_id
                       << ",\"device\":\"" << anvil256::json_escape(devname) << "\""
                       << ",\"nonce\":\""  << found_nonce << "\""
                       << ",\"hash\":\""   << anvil256::hash_to_hex(found_hash) << "\""
                       << ",\"hashes\":"   << job_hashes
                       << ",\"hashrate\":" << static_cast<std::uint64_t>(hashrate_ema)
                       << ",\"elapsed_ms\":" << (now - job_started)
                       << "}";
                    anvil256::emit(os.str());
                }
                have_job = false;
                break;
            }

            // ---- periodic progress report ----------------------------------
            if (now - last_emit_ms >= prog_ms) {
                last_emit_ms = now;
                std::ostringstream os;
                os << "{\"type\":\"progress\",\"job\":" << local_job_id
                   << ",\"device\":\"" << anvil256::json_escape(devname) << "\""
                   << ",\"hashes\":"   << job_hashes
                   << ",\"hashrate\":" << static_cast<std::uint64_t>(hashrate_ema)
                   << ",\"elapsed_ms\":" << (now - job_started)
                   << "}";
                anvil256::emit(os.str());
            }
        } // mining loop
    } // worker main loop
}

// ---------------------------------------------------------------------------
// Build per-thread contexts from env
// ---------------------------------------------------------------------------
std::vector<CpuCtx> build_contexts() {
    unsigned int hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;

    std::uint64_t n_threads = anvil256::env_u64("MINER_THREADS", hw);
    if (n_threads == 0) n_threads = 1;

    std::uint32_t npt = static_cast<std::uint32_t>(
        anvil256::env_u64("MINER_NPT", DEFAULT_NPT));
    if (npt == 0) npt = DEFAULT_NPT;
    npt = std::max(npt, static_cast<std::uint32_t>(MIN_NPT));
    npt = std::min(npt, static_cast<std::uint32_t>(MAX_NPT));

    double target_ms = anvil256::env_f64("MINER_TARGET_BATCH_MS", DEFAULT_TARGET_MS);
    target_ms = std::max(10.0, std::min(2000.0, target_ms));

    std::vector<CpuCtx> ctxs;
    ctxs.reserve(static_cast<std::size_t>(n_threads));
    for (std::uint64_t i = 0; i < n_threads; ++i) {
        CpuCtx c;
        c.index         = static_cast<std::size_t>(i);
        c.device_stride = i << 40;    // 2^40 nonce window per thread
        c.npt           = npt;
        c.target_ms     = target_ms;
        ctxs.push_back(c);
    }
    return ctxs;
}

// ---------------------------------------------------------------------------
// Common run entry (shared by interactive + one-shot modes)
// ---------------------------------------------------------------------------
int run_common(std::vector<CpuCtx>& ctxs, SharedState& st, bool interactive) {
    // Emit ready event.
    {
        std::ostringstream os;
        os << "{\"type\":\"ready\",\"devices\":[";
        for (std::size_t i = 0; i < ctxs.size(); ++i) {
            if (i) os << ',';
            os << "{\"index\":"  << i
               << ",\"name\":\"CPU:" << i << "\""
               << ",\"cu\":1"
               << ",\"wg\":1"
               << ",\"grid\":1"
               << ",\"npt\":"    << ctxs[i].npt
               << "}";
        }
        os << "]}";
        anvil256::emit(os.str());
    }

    // Spawn workers.
    std::vector<std::thread> workers;
    workers.reserve(ctxs.size());
    for (auto& ctx : ctxs)
        workers.emplace_back(cpu_worker, ctx, &st);

    if (interactive) {
        anvil256::stdin_reader(&st);
    } else {
        // One-shot: spin until found or exit requested.
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
// Interactive mode (Rust orchestrator subprocess)
// ---------------------------------------------------------------------------
int run_interactive() {
    auto ctxs = build_contexts();
    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);
    return run_common(ctxs, st, true);
}

// ---------------------------------------------------------------------------
// One-shot mode (ad-hoc benchmarks / offline verify)
// ---------------------------------------------------------------------------
int run_once(const std::string& inner_hex,
             const std::string& eps_hex,
             const std::string& diff_hex)
{
    std::uint8_t ib[32], eb[32], db[32];
    if (!anvil256::parse_hex32(inner_hex, ib) ||
        !anvil256::parse_hex32(eps_hex,   eb) ||
        !anvil256::parse_hex32(diff_hex,  db))
    {
        anvil256::emit_error("inner/entropy/difficulty must be 32-byte hex");
        return 1;
    }

    auto ctxs = build_contexts();
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

    return run_common(ctxs, st, false);
}

} // namespace

// =============================================================================
// Entry point
// =============================================================================
int main(int argc, char** argv) {
    if (argc >= 2 && std::strcmp(argv[1], "--once") == 0) {
        if (argc < 5) {
            std::cerr << "{\"type\":\"error\",\"message\":\"usage: ./miner-cpu --once "
                         "<inner_hex32> <entropy_hex32> <difficulty_hex32>\"}\n";
            return 2;
        }
        return run_once(argv[2], argv[3], argv[4]);
    }
    return run_interactive();
}