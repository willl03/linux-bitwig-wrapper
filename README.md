# linux-bitwig-wrapper

A CPU core-pinning and thread-limiting wrapper for **Bitwig Studio** running on hybrid CPU architectures.

By default on Linux, Bitwig scatters threads from the same process trees across both Performance (P) and Efficient (E) cores. This causes cache thrashing across different core clusters, leading to latency spikes and audio dropouts.

Additionnaly, Bitwig creates as many audio threads as total logical threads on the system, creating oversubscription on the CPU cores.

This project solves both problems:
1. **Core spoofing (`spoof-cores.sh`):** Uses a lightweight `LD_PRELOAD` shim to intercept glibc's `sysconf` processor enumeration, tricking Bitwig into spawning only **X audio threads** instead of matching the system's logical threads.
2. **Cluster pinning (`bitwig-wrap.sh`):** Directs the UI, PipeWire audio timings, JVM compilers, and garbage collection to P-cores, while grouping DSP audio workers, native Linux audio plugins, and Wine/yabridge VSTs entirely to E-cores.

> [!NOTE]
> **Made for my laptop with Intel Core Ultra 7 255H Meteor Lake (6 P-cores, 8 E-cores, 2 LPE cores)**
>
> Tested on Ubuntu Studio 26.04 (Kernel 7.2.2, PipeWire). I run 512 buffer size for safety; I could run 256 or 128 on most projects with this wrapper.

> [!WARNING]
> **You need to adjust the values to use this script with another CPU model**

---

## Topology layout (Core Ultra 7 255H)

| Cores | Type | Role in Wrapper |
| :--- | :--- | :--- |
| **0** | P-Core | Ignored (reserved for kernel interrupts / OS tasks) |
| **1-5** | P-Cores | **Bitwig UI, rendering, PipeWire audio timings, JVM compilers, GC** |
| **6-13** | E-Cores | **Audio engine DSP workers (8 threads), Linux plugins, Wine/yabridge VSTs** |
| **14-15** | LPE Cores | Ignored (unsuitable for low-latency audio) |

### Why E-cores for DSP?
On Meteor Lake, P-cores boost aggressively for burst workloads, while the 8 contiguous E-cores share a large L2 cache and run at consistent clock speeds with zero cross-cluster migration. Dedicating the entire E-core cluster to the audio DSP prevents cache synchronization stalls between audio threads and VST hosts.

---

## Installation & usage

### 1. Build the Core-Spoofing library (`spoof-cores.sh`)

Bitwig's audio thread calculation cannot be restricted with `taskset`. `spoof-cores.sh` compiles a minimal C shim (`/usr/local/lib/libspoof_cores.so`) that intercepts `sysconf(_SC_NPROCESSORS_ONLN)`. It is written without `malloc`/`calloc` during early initialization to prevent glibc `tcache` corruption and JVM startup aborts.

*Edit `SPOOFED_CORES` value if your target audio threads differs from `8`.*

> **Note:** You only need to run this **once** (or whenever you decide to adjust your target audio threads).

```bash
# Install standard build tools (if not already installed)
sudo apt update && sudo apt install -y build-essential

# Make executable and compile the shared object
chmod +x spoof-cores.sh
./spoof-cores.sh
```

> **Note:** It will ask for `sudo`. Open the script and run the individual commands if you prefer.

---

### 2. Configure and install the wrapper (`bitwig-wrap.sh`)

1. Open `bitwig-wrap.sh` and ensure the core ranges match your system:
   ```bash
   APPCORES="1-13"     # Skip core 0 (system interrupts) & cores 14-15 (LPE)
   PCORES="1-5"        # 5 P-cores for Bitwig UI, PipeWire audio timings, JVM compilers + GC
   ECORES="6-13"       # 8 E-cores for audio engine, threads (limited to 8), Linux plugins, Wine/yabridge VSTs
   ```

2. Make it executable and link it to your `$PATH`:
   ```bash
   chmod +x bitwig-wrap.sh
   sudo ln -sf "$(pwd)/bitwig-wrap.sh" /usr/local/bin/bitwig-wrap
   ```

3. Launch Bitwig with the wrapper:
   ```bash
   bitwig-wrap
   ```

---

## Verifications & observations

### Verifying pinning
Run this script while Bitwig is open to see the actual results:

```bash
./check-bitwig-pinning.sh
```

You can also verify that only 8 audio worker threads were spawned:
```bash
ps -T -C BitwigAudioEng | grep -E "audio-[0-9]+"
```

### Quirks & observations
- **Shared audio cluster:** Audio engine workers, plugin processes, and Wine VSTs perform significantly better when bound to the same physical cluster. Splitting the audio engine and plugins across P- and E-cores causes cache thrashing.
- **JVM GC:** JVM garbage collectors (such as `ZDriverMinor`) may float to E-cores depending on scheduler state; this has negligible impact.
- **Inherited affinities:** The wrapper does not require an ongoing background daemon or loop. Launch-time affinity rules are inherited by spawned subprocesses (including plugin hosts) throughout multi-hour sessions.
