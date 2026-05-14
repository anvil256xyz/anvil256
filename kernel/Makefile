# =====================================================================
# Anvil256 — keccak-256 PoW kernel
#
# Targets:
#   make            — cuda (default)
#   make cuda       — NVIDIA GPU path
#   make cpu        — portable C++ CPU fallback (pthreads, no CUDA)
#   make all        — build cuda + cpu
#   make cuda ARCHS="75 80 86 89 90 100 120"  — multi-arch fat binary
# =====================================================================

NVCC    ?= nvcc
CXX     ?= g++

# Output directory — CLI expects the binary at ../cli/bin/miner
BINDIR  := ../cli/bin

# ---- arch flags ----
ARCHS      ?= 89
PTX_ARCH   ?= $(lastword $(ARCHS))
ARCH_FLAGS := $(foreach a,$(ARCHS),-gencode arch=compute_$(a),code=sm_$(a)) \
              -gencode arch=compute_$(PTX_ARCH),code=compute_$(PTX_ARCH)

# ---- CUDA common flags ----
HARDEN_OFF    := -Xcompiler -U_FORTIFY_SOURCE -Xcompiler -D_FORTIFY_SOURCE=0
COMMON_CFLAGS := -O3 -std=c++17 -Xcompiler -pthread -Iinclude $(HARDEN_OFF)
RELEASE_FLAGS := -DNDEBUG -lineinfo
WARN_FLAGS    := -Xcompiler -Wall -Xcompiler -Wextra -Xcompiler -Wno-comment

# ---- CPU flags ----
CPU_CXXFLAGS := -O3 -std=c++17 -pthread -Iinclude \
                -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
                -DNDEBUG -march=native \
                -Wall -Wextra -Wno-comment

.PHONY: all cuda cpu clean help

all: cuda cpu

$(BINDIR):
	mkdir -p $(BINDIR)

cuda: $(BINDIR) $(BINDIR)/miner

$(BINDIR)/miner: miner.cu include/protocol.h
	$(NVCC) $(COMMON_CFLAGS) $(RELEASE_FLAGS) $(WARN_FLAGS) $(ARCH_FLAGS) \
	  miner.cu -o $@

cpu: $(BINDIR) $(BINDIR)/miner-cpu

$(BINDIR)/miner-cpu: miner_cpu.cpp include/protocol.h
	$(CXX) $(CPU_CXXFLAGS) miner_cpu.cpp -o $@

clean:
	rm -f $(BINDIR)/miner $(BINDIR)/miner-cpu

help:
	@echo "Targets:"
	@echo "  make              — build CUDA miner → $(BINDIR)/miner"
	@echo "  make cpu          — build CPU fallback → $(BINDIR)/miner-cpu"
	@echo "  make all          — build both cuda + cpu"
	@echo "  make cuda ARCHS=\"75 80 86 89 90 100 120\""
	@echo "                    — multi-arch CUDA fat binary incl. RTX 50-series"
	@echo "  make cuda ARCHS=\"120\""
	@echo "                    — RTX 5060/5070/5080/5090 native sm_120 + PTX"
	@echo "  make clean        — remove build artifacts from $(BINDIR)"
	@echo ""
	@echo "CPU miner env vars:"
	@echo "  MINER_THREADS=N          worker threads (default: nproc)"
	@echo "  MINER_NPT=128            nonces per batch"
	@echo "  MINER_PROGRESS_MS=750    progress emit period"
