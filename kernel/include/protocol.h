/*
 * =====================================================================
 *  Anvil256 — kernel/host JSON protocol (stable, versioned)
 *
 *  The Rust orchestrator (cli/) spawns this miner as a subprocess and
 *  exchanges line-delimited JSON on stdin/stdout. The protocol is
 *  deliberately kernel-agnostic, so we can swap CUDA → OpenCL → Metal →
 *  Vulkan without touching the orchestrator.
 *
 *  --- versioning ---
 *
 *      v1 (current): plain string commands on stdin, one JSON object
 *                    per line on stdout. No framing layer.
 *
 *  --- stdin (host → miner) ---
 *
 *      "JOB <inner_hex64> <epoch_entropy_hex64> <difficulty_hex64> <job_id_decimal>\n"
 *      "STOP\n"
 *      "EXIT\n"
 *
 *  Examples:
 *      JOB 95c3eff41215fcee37e84deb6a3be65a901a24156b99e01ba47a9736957f4af4 \
 *          11223344556677889900aabbccddeeff00112233445566778899aabbccddeeff \
 *          000000000000000DA74D8E71E0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF 7
 *
 *  --- stdout (miner → host) ---
 *
 *      One JSON object per line, with a discriminator field "type":
 *
 *      {"type":"ready",   "devices":[ {DeviceInfo}, ... ]}
 *      {"type":"progress","job":N, "device":"<name>",
 *                         "hashes":N, "hashrate":FLOAT, "elapsed_ms":N}
 *      {"type":"found",   "job":N, "device":"<name>",
 *                         "nonce":"<decimal u256>",
 *                         "hash":"0x<hex64>",
 *                         "hashes":N, "hashrate":FLOAT, "elapsed_ms":N}
 *      {"type":"error",   "message":"<text>"}
 *
 *      DeviceInfo:
 *      {
 *          "index": <gpu index>,
 *          "name":  "<vendor name>",
 *          "cu":    <SM / CU count>,
 *          "wg":    <block size in threads>,
 *          "grid":  <launched blocks>,
 *          "npt":   <nonces per thread per launch>
 *      }
 *
 *  --- compute semantics (Anvil256 Cascade PoW) ---
 *
 *      inner     : 32-byte big-endian ι(m,n) = getInner(miner) from the
 *                  contract. Folds in miner address, γ(m), genesisBlockHash
 *                  and the current epoch.
 *      entropy   : 32-byte big-endian ε[n] = epochEntropy from the contract.
 *      difficulty: 32-byte big-endian; valid iff hash < difficulty (byte-by-
 *                  byte BE compare interpreted as a uint256).
 *      nonce     : uint256, scanned monotonically per device starting at
 *                  (base + device_index * 2^56).
 *      hash      : Cascade keccak-256, two passes:
 *                    mid    = keccak256( abi.encode(inner, nonce_be32) )
 *                    result = keccak256( abi.encode(mid,   entropy)    )
 *                  i.e.  κ(m,ν,n) = H(H(ι ‖ ν) ‖ ε[n]).
 *                  Both passes use abi.encode (32-byte left-padded), NOT
 *                  abi.encodePacked. Off-chain kernels MUST replicate this
 *                  exactly or every nonce will be rejected on-chain.
 *
 *  --- guarantees ---
 *
 *      1. The miner subprocess MUST emit exactly one "ready" event before
 *         any other event. The host blocks until it sees this event.
 *      2. After a JOB, the miner emits 0..N "progress" events followed by
 *         exactly one of: "found", "error", or (on STOP) silence until
 *         the next JOB.
 *      3. EXIT terminates the process within 100 ms.
 *
 *  --- forward compatibility ---
 *
 *      Unknown stdin commands MUST be ignored.
 *      Unknown stdout fields MUST be ignored by the host.
 * =====================================================================
 */
#ifndef ANVIL256_PROTOCOL_H
#define ANVIL256_PROTOCOL_H

#define ANVIL256_PROTO_VERSION 1

/* event type strings (must stay stable across versions) */
#define ANVIL256_EVT_READY    "ready"
#define ANVIL256_EVT_PROGRESS "progress"
#define ANVIL256_EVT_FOUND    "found"
#define ANVIL256_EVT_ERROR    "error"

/* command tokens (first whitespace-delimited word on each stdin line) */
#define ANVIL256_CMD_JOB  "JOB"
#define ANVIL256_CMD_STOP "STOP"
#define ANVIL256_CMD_EXIT "EXIT"

#endif /* ANVIL256_PROTOCOL_H */
