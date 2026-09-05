# linux-bitwig-wrapper
Bitwig CPU wrapper that works best for my laptop with Core 7 255H (6 P-cores, 8 E-cores and 2 LPE cores).

By default Bitwig is a mess on non-monolithic CPU architectures (at least on Linux); it scatters threads from the same processes and groups across P-cores and E-cores. Because of this, threads don't share cache, leading to latency and DSP/CPU spikes. This wrapper fixes this.

Tested on Ubuntu Studio 26.04 with 7.2.2 kernel on Meteor Lake CPU with PipeWire audio. I run 512 buffer size for safety; I could run 256 or 128 on most projects with this wrapper.

# What it does
With my values, Bitwig runs on core 1-13:
- Core 0: Ignored P-core for system interupts
- Core 1-5: P-cores used for the main thread, rendering, audio timings, JVM compilers and garbage collectors.
- Core 6-13: E-cores used audio threads, internal / native Linux plugins and Wine VSTs.
- Core 14-15: Ignored LPE cores

Somehow this works better than the opposite on my system (P-cores for audio and E-cores for other threads). Probably because of higher thread count and bigger L2 cache. On Meteor Lake, P-cores are for burst, E-cores are for stability (such as audio threads).

The script also includes some tweaks to soften JVM compilers and some Wine VSTs.

# Usage
- Adjust the APPCORES, PCORES and ECORES values for your own system.
- chmod +x bitwig-wrap.sh
- sudo ln -s /path-to/bitwig-wrap.sh /usr/local/bin/bitwig-wrap
- bitwig-wrap

# Observations
- Audio engine & DSP workers, audio plugins and Wine VSTs work incredibly better when they share the same cores. In my system, they work better on the E-cores.
- Bitwig's rendering, audio timings (PipeWire + data-loop) and JVM compilers & garbage collectors work fine on the P-cores.
- The result is a balanced load across P- and E-cores, lowest average DSP latency observed in my system with little to no spikes.
- This script doesn't need a loop to reapply; it is a one-shot and the rules applied on launch are inherited by child processes / threads even during hourslong sessions.

# Culprits
- Sometimes BitwigStudio (Main) parks on E-cores despite being pinned to P-cores, either is fine.
- Sometimes ZDriverMinor parks on E-cores despite being pinned to P-cores, it is stubborn.
- The script is unintuitive, the results don't exactly matches the content of the script, but the results match what I want & what works best for my system.
- Don't trust the CPU affinities in the script, run the "check-bitwig-pinning.sh" script to see the actual results.