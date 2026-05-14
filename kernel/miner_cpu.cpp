// =============================================================================
// miner_cpu.cpp — CPU fallback for Anvil256 Cascade PoW
//
// Drop-in replacement for miner.cu when CUDA is unavailable.
// Same stdin/stdout JSON protocol (protocol.h).
// Uses std::thread, one thread per logical CPU core by default.
//
// Env vars (same names as CUDA build where applicable):
//   MINER_THREADS=N          worker thread count (default: hw_concurrency)
//   MINER_NPT=128            nonces per inner loop iteration (default 128)
//   MINER_TARGET_BATCH_MS=250  unused for CPU, kept for compat
//   MINER_PROGRESS_MS=750    progress emit period in ms
//   MINER_DEVICES=0          ignored (no GPU indices on CPU build)
// =============================================================================

#include "protocol.h"

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
// Keccak-256 — portable C++ (identical math to the CUDA device kernel)
// =============================================================================

static inline std::uint64_t rotl64(std::uint64_t x, int n) {
    return (x << n) | (x >> (64 - n));
}

static inline std::uint64_t bswap64(std::uint64_t v) {
    return ((v & 0x00000000000000FFULL) << 56)
         | ((v & 0x000000000000FF00ULL) << 40)
         | ((v & 0x0000000000FF0000ULL) << 24)
         | ((v & 0x00000000FF000000ULL) <<  8)
         | ((v & 0x000000FF00000000ULL) >>  8)
         | ((v & 0x0000FF0000000000ULL) >> 24)
         | ((v & 0x00FF000000000000ULL) >> 40)
         | ((v & 0xFF00000000000000ULL) >> 56);
}

#define KECCAK_R(rc)                                                            \
    do {                                                                        \
        const std::uint64_t C0 = a00^a05^a10^a15^a20;                          \
        const std::uint64_t C1 = a01^a06^a11^a16^a21;                          \
        const std::uint64_t C2 = a02^a07^a12^a17^a22;                          \
        const std::uint64_t C3 = a03^a08^a13^a18^a23;                          \
        const std::uint64_t C4 = a04^a09^a14^a19^a24;                          \
        const std::uint64_t D0 = C4^rotl64(C1,1);                              \
        const std::uint64_t D1 = C0^rotl64(C2,1);                              \
        const std::uint64_t D2 = C1^rotl64(C3,1);                              \
        const std::uint64_t D3 = C2^rotl64(C4,1);                              \
        const std::uint64_t D4 = C3^rotl64(C0,1);                              \
        a00^=D0; a05^=D0; a10^=D0; a15^=D0; a20^=D0;                           \
        a01^=D1; a06^=D1; a11^=D1; a16^=D1; a21^=D1;                           \
        a02^=D2; a07^=D2; a12^=D2; a17^=D2; a22^=D2;                           \
        a03^=D3; a08^=D3; a13^=D3; a18^=D3; a23^=D3;                           \
        a04^=D4; a09^=D4; a14^=D4; a19^=D4; a24^=D4;                           \
        const std::uint64_t B00=a00;                                            \
        const std::uint64_t B10=rotl64(a01, 1);                                 \
        const std::uint64_t B20=rotl64(a02,62);                                 \
        const std::uint64_t B05=rotl64(a03,28);                                 \
        const std::uint64_t B15=rotl64(a04,27);                                 \
        const std::uint64_t B16=rotl64(a05,36);                                 \
        const std::uint64_t B01=rotl64(a06,44);                                 \
        const std::uint64_t B11=rotl64(a07, 6);                                 \
        const std::uint64_t B21=rotl64(a08,55);                                 \
        const std::uint64_t B06=rotl64(a09,20);                                 \
        const std::uint64_t B07=rotl64(a10, 3);                                 \
        const std::uint64_t B17=rotl64(a11,10);                                 \
        const std::uint64_t B02=rotl64(a12,43);                                 \
        const std::uint64_t B12=rotl64(a13,25);                                 \
        const std::uint64_t B22=rotl64(a14,39);                                 \
        const std::uint64_t B23=rotl64(a15,41);                                 \
        const std::uint64_t B08=rotl64(a16,45);                                 \
        const std::uint64_t B18=rotl64(a17,15);                                 \
        const std::uint64_t B03=rotl64(a18,21);                                 \
        const std::uint64_t B13=rotl64(a19, 8);                                 \
        const std::uint64_t B14=rotl64(a20,18);                                 \
        const std::uint64_t B24=rotl64(a21, 2);                                 \
        const std::uint64_t B09=rotl64(a22,61);                                 \
        const std::uint64_t B19=rotl64(a23,56);                                 \
        const std::uint64_t B04=rotl64(a24,14);                                 \
        a00=B00^((~B01)&B02); a01=B01^((~B02)&B03); a02=B02^((~B03)&B04);      \
        a03=B03^((~B04)&B00); a04=B04^((~B00)&B01);                            \
        a05=B05^((~B06)&B07); a06=B06^((~B07)&B08); a07=B07^((~B08)&B09);      \
        a08=B08^((~B09)&B05); a09=B09^((~B05)&B06);                            \
        a10=B10^((~B11)&B12); a11=B11^((~B12)&B13); a12=B12^((~B13)&B14);      \
        a13=B13^((~B14)&B10); a14=B14^((~B10)&B11);                            \
        a15=B15^((~B16)&B17); a16=B16^((~B17)&B18); a17=B17^((~B18)&B19);      \
        a18=B18^((~B19)&B15); a19=B19^((~B15)&B16);                            \
        a20=B20^((~B21)&B22); a21=B21^((~B22)&B23); a22=B22^((~B23)&B24);      \
        a23=B23^((~B24)&B20); a24=B24^((~B20)&B21);                            \
        a00^=(rc);                                                              \
    } while(0)

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

// Compute Cascade keccak: κ = H(H(inner ‖ nonce_be32) ‖ entropy)
// inner[4], entropy[4] are LE u64. diff[4] are BE u64.
// Returns true if hash < difficulty; writes hash_out[4] (BE u64).
static bool cascade_hash(
    const std::uint64_t inner[4],
    const std::uint64_t entropy[4],
    const std::uint64_t diff[4],
    std::uint64_t nonce,
    std::uint64_t hash_out[4])
{
    // Pass 1: keccak256(abi.encode(inner, nonce))
    std::uint64_t a00=inner[0], a01=inner[1], a02=inner[2], a03=inner[3];
    std::uint64_t a04=0, a05=0, a06=0;
    std::uint64_t a07=bswap64(nonce);
    std::uint64_t a08=1ULL;
    std::uint64_t a09=0, a10=0, a11=0, a12=0;
    std::uint64_t a13=0, a14=0, a15=0;
    std::uint64_t a16=0x8000000000000000ULL;
    std::uint64_t a17=0, a18=0, a19=0;
    std::uint64_t a20=0, a21=0, a22=0, a23=0, a24=0;
    KECCAK_24_ROUNDS;

    const std::uint64_t m0=a00, m1=a01, m2=a02, m3=a03;

    // Pass 2: keccak256(abi.encode(mid, entropy))
    a00=m0; a01=m1; a02=m2; a03=m3;
    a04=entropy[0]; a05=entropy[1]; a06=entropy[2]; a07=entropy[3];
    a08=1ULL;
    a09=0; a10=0; a11=0; a12=0;
    a13=0; a14=0; a15=0;
    a16=0x8000000000000000ULL;
    a17=0; a18=0; a19=0;
    a20=0; a21=0; a22=0; a23=0; a24=0;
    KECCAK_24_ROUNDS;

    // BE compare
    const std::uint64_t h0=bswap64(a00), h1=bswap64(a01),
                        h2=bswap64(a02), h3=bswap64(a03);
    hash_out[0]=h0; hash_out[1]=h1; hash_out[2]=h2; hash_out[3]=h3;

    if (h0 != diff[0]) return h0 < diff[0];
    if (h1 != diff[1]) return h1 < diff[1];
    if (h2 != diff[2]) return h2 < diff[2];
    return h3 < diff[3];
}

// =============================================================================
// Shared state (mirrors CUDA build)
// =============================================================================

struct Job {
    std::uint64_t id            = 0;
    std::uint64_t inner[4]      = {};
    std::uint64_t entropy[4]    = {};
    std::uint64_t difficulty[4] = {};
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
// I/O helpers (identical to CUDA build)
// =============================================================================

namespace {

std::mutex g_io_mu;

std::string trim(const std::string& s) {
    auto b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    return s.substr(b, s.find_last_not_of(" \t\r\n") - b + 1);
}

std::string json_escape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if      (c == '"')  out += "\\\"";
        else if (c == '\\') out += "\\\\";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (static_cast<unsigned char>(c) < 0x20) {
            char buf[8]; std::snprintf(buf, sizeof(buf), "\\u%04x", c & 0xff);
            out += buf;
        } else out += c;
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
    if (c>='0'&&c<='9') return c-'0';
    if (c>='a'&&c<='f') return c-'a'+10;
    if (c>='A'&&c<='F') return c-'A'+10;
    return -1;
}

bool parse_hex32(const std::string& s, std::uint8_t out[32]) {
    const char* p = s.c_str(); std::size_t n = s.size();
    if (n>=2 && p[0]=='0' && (p[1]=='x'||p[1]=='X')) { p+=2; n-=2; }
    if (n!=64) return false;
    for (std::size_t i=0; i<32; ++i) {
        int hi=hex_nibble(p[i*2]), lo=hex_nibble(p[i*2+1]);
        if (hi<0||lo<0) return false;
        out[i] = static_cast<std::uint8_t>((hi<<4)|lo);
    }
    return true;
}

std::uint64_t load_le64(const std::uint8_t* p) {
    std::uint64_t v=0;
    for (int i=0;i<8;++i) v|=static_cast<std::uint64_t>(p[i])<<(i*8);
    return v;
}

std::uint64_t load_be64(const std::uint8_t* p) {
    std::uint64_t v=0;
    for (int i=0;i<8;++i) v=(v<<8)|static_cast<std::uint64_t>(p[i]);
    return v;
}

std::string hash_to_hex(const std::uint64_t h[4]) {
    char buf[67]; char* p=buf; *p++='0'; *p++='x';
    for (int i=0;i<4;++i) {
        std::uint64_t w=h[i];
        for (int b=7;b>=0;--b) {
            std::snprintf(p,3,"%02x",(std::uint8_t)(w>>(b*8))); p+=2;
        }
    }
    *p='\0'; return std::string(buf);
}

std::uint64_t env_u64(const char* name, std::uint64_t def) {
    const char* v=std::getenv(name);
    if (!v||!*v) return def;
    char* e=nullptr; unsigned long long r=std::strtoull(v,&e,0);
    return (e==v) ? def : (std::uint64_t)r;
}

std::uint64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// =============================================================================
// CPU worker thread
// =============================================================================

struct CpuCtx {
    std::size_t   index         = 0;
    std::uint64_t device_stride = 0;
    std::uint32_t npt           = 128;
    double        target_ms     = 250.0;
};

void cpu_worker(CpuCtx ctx, SharedState* st) {
    std::uint64_t local_job_id  = 0;
    std::uint64_t job_started   = 0;
    std::uint64_t job_hashes    = 0;
    double        hashrate_ema  = 0.0;
    std::uint64_t last_emit_ms  = 0;
    std::uint64_t base_nonce    = 0;
    bool          have_job      = false;

    const std::uint64_t prog_ms = env_u64("MINER_PROGRESS_MS", 750);
    const std::string   devname = "CPU:" + std::to_string(ctx.index);

    while (!st->exit_requested.load(std::memory_order_acquire)) {
        std::uint64_t inner[4]={}, eps[4]={}, diff[4]={};

        // wait for active job
        {
            std::unique_lock<std::mutex> lk(st->mu);
            st->cv.wait(lk, [&]{
                return st->exit_requested.load() ||
                       (st->job.active && st->job.id != local_job_id);
            });
            if (st->exit_requested.load()) break;
            const Job& j = st->job;
            local_job_id  = j.id;
            for (int i=0;i<4;++i) inner[i] = j.inner[i];
            for (int i=0;i<4;++i) eps[i]   = j.entropy[i];
            for (int i=0;i<4;++i) diff[i]  = j.difficulty[i];
            base_nonce    = j.base_nonce + ctx.device_stride;
            have_job      = true;
            job_started   = now_ms();
            job_hashes    = 0;
            hashrate_ema  = 0.0;
            last_emit_ms  = job_started;
            st->found_in_job.store(false, std::memory_order_release);
        }

        while (have_job && !st->exit_requested.load(std::memory_order_acquire)) {
            {
                std::lock_guard<std::mutex> lk(st->mu);
                if (st->job.id!=local_job_id || !st->job.active) { have_job=false; break; }
            }
            if (st->found_in_job.load(std::memory_order_acquire)) { have_job=false; break; }

            const std::uint64_t batch_start = now_ms();
            const std::uint64_t batch_count = (std::uint64_t)ctx.npt;

            std::uint64_t found_nonce = 0;
            std::uint64_t found_hash[4] = {};
            bool          found = false;

            for (std::uint64_t k = 0; k < batch_count; ++k) {
                std::uint64_t h[4];
                if (cascade_hash(inner, eps, diff, base_nonce + k, h)) {
                    found_nonce = base_nonce + k;
                    found_hash[0]=h[0]; found_hash[1]=h[1];
                    found_hash[2]=h[2]; found_hash[3]=h[3];
                    found = true;
                    break;
                }
            }

            base_nonce  += batch_count;
            job_hashes  += batch_count;

            const std::uint64_t now    = now_ms();
            std::uint64_t       bms    = now - batch_start;
            if (bms == 0) bms = 1;
            const double rate = (double)batch_count * 1000.0 / (double)bms;
            hashrate_ema = (hashrate_ema == 0.0)
                ? rate : (0.3*rate + 0.7*hashrate_ema);

            // simple adaptive npt: ramp toward target_ms
            const double tgt = ctx.target_ms;
            if ((double)bms < tgt * 0.5) {
                std::uint64_t n = (std::uint64_t)((double)ctx.npt * tgt / (double)bms);
                if (n > ctx.npt * 4ULL) n = ctx.npt * 4ULL;
                if (n > 1048576ULL)     n = 1048576ULL;
                ctx.npt = (std::uint32_t)n;
            } else if ((double)bms > tgt * 4.0) {
                std::uint64_t n = (std::uint64_t)((double)ctx.npt * tgt / (double)bms);
                if (n < 1) n = 1;
                ctx.npt = (std::uint32_t)n;
            }

            if (found) {
                if (!st->found_in_job.exchange(true, std::memory_order_acq_rel)) {
                    std::ostringstream os;
                    os << "{\"type\":\"found\",\"job\":" << local_job_id
                       << ",\"device\":\"" << json_escape(devname) << "\""
                       << ",\"nonce\":\""  << found_nonce << "\""
                       << ",\"hash\":\""   << hash_to_hex(found_hash) << "\""
                       << ",\"hashes\":"   << job_hashes
                       << ",\"hashrate\":" << (std::uint64_t)hashrate_ema
                       << ",\"elapsed_ms\":" << (now - job_started)
                       << "}";
                    emit(os.str());
                }
                have_job = false;
                break;
            }

            if (now - last_emit_ms >= prog_ms) {
                last_emit_ms = now;
                std::ostringstream os;
                os << "{\"type\":\"progress\",\"job\":" << local_job_id
                   << ",\"device\":\"" << json_escape(devname) << "\""
                   << ",\"hashes\":"   << job_hashes
                   << ",\"hashrate\":" << (std::uint64_t)hashrate_ema
                   << ",\"elapsed_ms\":" << (now - job_started)
                   << "}";
                emit(os.str());
            }
        }
    }
}

// =============================================================================
// Job parsing + stdin reader (identical to CUDA build)
// =============================================================================

bool parse_job_line(const std::string& line, Job& job, std::string& err) {
    std::istringstream is(line);
    std::string cmd, inner_s, eps_s, diff_s, id_s;
    is >> cmd >> inner_s >> eps_s >> diff_s >> id_s;
    if (cmd!="JOB"||inner_s.empty()||eps_s.empty()||diff_s.empty()) {
        err="expected: JOB <inner_hex32> <entropy_hex32> <difficulty_hex32> [job_id]";
        return false;
    }
    std::uint8_t ib[32], eb[32], db[32];
    if (!parse_hex32(inner_s,ib)){err="inner must be 32-byte hex";return false;}
    if (!parse_hex32(eps_s,  eb)){err="entropy must be 32-byte hex";return false;}
    if (!parse_hex32(diff_s, db)){err="difficulty must be 32-byte hex";return false;}
    for (int i=0;i<4;++i) job.inner[i]      = load_le64(ib+i*8);
    for (int i=0;i<4;++i) job.entropy[i]    = load_le64(eb+i*8);
    for (int i=0;i<4;++i) job.difficulty[i] = load_be64(db+i*8);
    std::random_device rd;
    job.base_nonce = ((std::uint64_t)rd()<<32)^(std::uint64_t)rd();
    job.active = true;
    return true;
}

void stdin_reader(SharedState* st) {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (st->exit_requested.load()) break;
        line = trim(line);
        if (line.empty()) continue;
        if (line.rfind("JOB",0)==0) {
            Job j; std::string err;
            if (!parse_job_line(line,j,err)) { emit_error(err); continue; }
            {
                std::lock_guard<std::mutex> lk(st->mu);
                j.id = st->next_job_id++;
                st->job = j;
                st->found_in_job.store(false, std::memory_order_release);
            }
            st->cv.notify_all();
        } else if (line=="STOP") {
            {
                std::lock_guard<std::mutex> lk(st->mu);
                st->job.active = false;
                st->job.id = st->next_job_id++;
            }
            st->cv.notify_all();
        } else if (line=="EXIT"||line=="QUIT") {
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
// run_common / run_interactive / run_once
// =============================================================================

int run_common(std::vector<CpuCtx>& ctxs, SharedState& st, bool interactive) {
    // Ready event
    {
        std::ostringstream os;
        os << "{\"type\":\"ready\",\"devices\":[";
        for (std::size_t i=0; i<ctxs.size(); ++i) {
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
        emit(os.str());
    }

    std::vector<std::thread> workers;
    for (auto& ctx : ctxs)
        workers.emplace_back(cpu_worker, ctx, &st);

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

int run_interactive() {
    unsigned int hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;
    std::uint64_t n_threads = env_u64("MINER_THREADS", hw);
    if (n_threads == 0) n_threads = 1;

    std::uint32_t npt = (std::uint32_t)env_u64("MINER_NPT", 128);
    if (npt == 0) npt = 128;

    std::vector<CpuCtx> ctxs;
    for (std::uint64_t i = 0; i < n_threads; ++i) {
        CpuCtx c;
        c.index         = (std::size_t)i;
        c.device_stride = i << 40;   // 2^40 nonce-space offset per thread
        c.npt           = npt;
        ctxs.push_back(c);
    }

    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);

    return run_common(ctxs, st, true);
}

int run_once(const std::string& inner_hex,
             const std::string& eps_hex,
             const std::string& diff_hex)
{
    unsigned int hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;
    std::uint64_t n_threads = env_u64("MINER_THREADS", hw);
    if (n_threads == 0) n_threads = 1;
    std::uint32_t npt = (std::uint32_t)env_u64("MINER_NPT", 128);

    std::uint8_t ib[32], eb[32], db[32];
    if (!parse_hex32(inner_hex,ib)||!parse_hex32(eps_hex,eb)||!parse_hex32(diff_hex,db)) {
        emit_error("inner/entropy/difficulty must be 32-byte hex"); return 1;
    }

    std::vector<CpuCtx> ctxs;
    for (std::uint64_t i=0; i<n_threads; ++i) {
        CpuCtx c; c.index=(std::size_t)i; c.device_stride=i<<40; c.npt=npt;
        ctxs.push_back(c);
    }

    SharedState st;
    g_state_ptr = &st;
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);

    Job j;
    for (int i=0;i<4;++i) j.inner[i]      = load_le64(ib+i*8);
    for (int i=0;i<4;++i) j.entropy[i]    = load_le64(eb+i*8);
    for (int i=0;i<4;++i) j.difficulty[i] = load_be64(db+i*8);
    std::random_device rd;
    j.base_nonce = ((std::uint64_t)rd()<<32)^(std::uint64_t)rd();
    j.active=true; j.id=1; st.next_job_id=2; st.job=j;

    return run_common(ctxs, st, false);
}

} // namespace

// =============================================================================
// Entry point
// =============================================================================

int main(int argc, char** argv) {
    if (argc>=2 && std::strcmp(argv[1],"--once")==0) {
        if (argc<5) {
            std::cerr << "{\"type\":\"error\",\"message\":\"usage: ./miner --once "
                         "<inner_hex32> <entropy_hex32> <difficulty_hex32>\"}\n";
            return 2;
        }
        return run_once(argv[2], argv[3], argv[4]);
    }
    return run_interactive();
}