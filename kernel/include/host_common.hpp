#pragma once
// =============================================================================
// host_common.hpp — shared protocol helpers for Anvil256 GPU/CPU miners
//
// Provides: Job struct, SharedState, JSON emitters, hex parsing, env helpers,
// stdin reader. Included by both miner.cu (CUDA) and miner_cpu.cpp (CPU).
// =============================================================================

#include "protocol.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <random>
#include <sstream>
#include <string>

namespace anvil256 {

// =============================================================================
// Job + shared state
// =============================================================================

// Host-side representation of one mining job.
//   inner / entropy : little-endian u64 lanes for direct Keccak absorption.
//   difficulty      : big-endian  u64 words  for uint256 comparisons.
//   base_nonce      : randomised per job; workers add their own disjoint stride.
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

// =============================================================================
// I/O helpers
// =============================================================================

inline std::mutex g_io_mu;

inline std::string trim(const std::string& s) {
    auto b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    auto e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

inline std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 4);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

inline void emit(const std::string& line) {
    std::lock_guard<std::mutex> lk(g_io_mu);
    std::cout << line << '\n';
    std::cout.flush();
}

inline void emit_error(const std::string& msg) {
    std::ostringstream os;
    os << "{\"type\":\"error\",\"message\":\"" << json_escape(msg) << "\"}";
    emit(os.str());
}

// =============================================================================
// Hex / byte helpers
// =============================================================================

inline int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Decode exactly 32 bytes from a 64-char hex string (0x prefix optional).
inline bool parse_hex32(const std::string& s, std::uint8_t out[32]) {
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

inline std::uint64_t load_le64(const std::uint8_t* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= static_cast<std::uint64_t>(p[i]) << (i * 8);
    return v;
}

inline std::uint64_t load_be64(const std::uint8_t* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | static_cast<std::uint64_t>(p[i]);
    return v;
}

// Encode 4× BE u64 words as "0x<64-hex-char>" string.
inline std::string hash_to_hex(const std::uint64_t hash[4]) {
    char buf[2 + 64 + 1];
    char* p = buf;
    *p++ = '0'; *p++ = 'x';
    for (int i = 0; i < 4; ++i) {
        std::uint64_t w = hash[i];
        for (int b = 7; b >= 0; --b) {
            std::snprintf(p, 3, "%02x", static_cast<std::uint8_t>(w >> (b * 8)));
            p += 2;
        }
    }
    *p = '\0';
    return std::string(buf);
}

inline std::string u64_to_dec(std::uint64_t v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%llu", static_cast<unsigned long long>(v));
    return std::string(buf);
}

// =============================================================================
// Env helpers
// =============================================================================

inline std::uint64_t env_u64(const char* name, std::uint64_t fallback) {
    const char* v = std::getenv(name);
    if (!v || !*v) return fallback;
    char* end = nullptr;
    unsigned long long r = std::strtoull(v, &end, 0);
    return (end == v) ? fallback : static_cast<std::uint64_t>(r);
}

inline double env_f64(const char* name, double fallback) {
    const char* v = std::getenv(name);
    if (!v || !*v) return fallback;
    char* end = nullptr;
    double r = std::strtod(v, &end);
    return (end == v) ? fallback : r;
}

// =============================================================================
// Misc helpers
// =============================================================================

inline std::uint64_t now_ms() {
    using namespace std::chrono;
    return static_cast<std::uint64_t>(
        duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

inline void fill_random_base_nonce(Job& job) {
    std::random_device rd;
    job.base_nonce = (static_cast<std::uint64_t>(rd()) << 32)
                   ^ static_cast<std::uint64_t>(rd());
}

// =============================================================================
// JOB line parser
// =============================================================================

// Parses: "JOB <inner_hex32> <entropy_hex32> <difficulty_hex32> <job_id_dec>"
// inner / entropy → little-endian u64 lanes.
// difficulty      → big-endian  u64 words.
inline bool parse_job_line(const std::string& line, Job& job, std::string& err) {
    std::istringstream is(line);
    std::string cmd, inner_s, eps_s, diff_s, id_s;
    is >> cmd >> inner_s >> eps_s >> diff_s >> id_s;

    if (cmd != "JOB" || inner_s.empty() || eps_s.empty() || diff_s.empty() || id_s.empty()) {
        err = "expected: JOB <inner_hex32> <entropy_hex32> <difficulty_hex32> <job_id>";
        return false;
    }

    std::uint8_t ib[32], eb[32], db[32];
    if (!parse_hex32(inner_s, ib)) { err = "inner must be 32-byte hex";      return false; }
    if (!parse_hex32(eps_s,   eb)) { err = "entropy must be 32-byte hex";    return false; }
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
    fill_random_base_nonce(job);
    job.active = true;
    return true;
}

// =============================================================================
// Stdin reader (runs on its own thread; feeds SharedState)
// =============================================================================

inline void stdin_reader(SharedState* st) {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (st->exit_requested.load()) break;
        line = trim(line);
        if (line.empty()) continue;

        if (line.rfind("JOB", 0) == 0) {
            Job j;
            std::string err;
            if (!parse_job_line(line, j, err)) { emit_error(err); continue; }
            {
                std::lock_guard<std::mutex> lk(st->mu);
                st->job = j;
                if (j.id >= st->next_job_id && j.id != UINT64_MAX)
                    st->next_job_id = j.id + 1;
                st->found_in_job.store(false, std::memory_order_release);
            }
            st->cv.notify_all();

        } else if (line == "STOP") {
            {
                std::lock_guard<std::mutex> lk(st->mu);
                st->job.active = false;
                st->job.id     = st->next_job_id++;
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
    // EOF / pipe-close → treat as EXIT
    st->exit_requested.store(true, std::memory_order_release);
    st->cv.notify_all();
}

} // namespace anvil256