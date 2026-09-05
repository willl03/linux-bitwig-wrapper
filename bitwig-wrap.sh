#!/bin/bash
# ==============================================================================
# Bitwig Studio CPU Wrapper
# Tested on Ubuntu 26.04 with Core 7 255H (6 P-cores, 8 E-cores and 2 LPE cores)
# ==============================================================================
set -uo pipefail

# 1. PipeWire Quantum & Target Latency
export PIPEWIRE_LATENCY="512/48000"
export PIPEWIRE_QUANTUM="512/48000"

# 2. Wine & yabridge Synchronization
export WINEFSYNC=1
export WINEDEBUG="-all"
export WINE_DISABLE_BUG_REPORT=1

# Tame DXVK to prevent compiler thread floods while allowing the GUI to embed
export DXVK_NUM_COMPILER_THREADS=1
export DXVK_STATE_CACHE=0
export DXVK_ASYNC=0

export MESA_VK_ENABLE_SUBALLOC=0
export LIBVA_DRIVER_NAME=iHD

# 3. JVM Tuning: Low-latency ZGC + Software 2D (prevents Intel Xe TLB timeouts)
export JAVA_TOOL_OPTIONS="-XX:+UseZGC -XX:ConcGCThreads=1 -XX:CICompilerCount=2 -XX:TieredStopAtLevel=1 -Dsun.java2d.opengl=false"

# 4. Set core groups and launch Bitwig pinned to APPCORES
APPCORES="1-13"     # Skip core 0 (system interrupts) & cores 14-15 (LPE)
PCORES="1-5"        # 5 P-cores for PipeWire / audio timings
ECORES="6-13"       # 8 E-cores for Bitwig GUI, audio engine & JVM

systemd-run --user --scope -p AllowedCPUs="$APPCORES" /usr/bin/bitwig-studio "$@" &
LAUNCH_PID=$!

(
    # --- Phase A: Route main process & JVM to E-cores ---
    for i in {1..100}; do
        MAIN_PID=$(pgrep -u "$UID" -x "BitwigStudio" | head -n1)
        if [ -n "$MAIN_PID" ]; then
            taskset -a -pc "$ECORES" "$MAIN_PID" >/dev/null 2>&1

            sleep 9
            for tid in $(ps -T -p "$MAIN_PID" -o spid,comm 2>/dev/null | grep -E "Compiler|ZDriverMinor" | awk '{print $1}'); do
                taskset -a -pc "$PCORES" "$tid" >/dev/null 2>&1
                chrt -b -p 0 "$tid" >/dev/null 2>&1
                renice -n 10 -p "$tid" >/dev/null 2>&1
            done
            break
        fi
        sleep 1
    done

    # --- Phase B: Route Audio Engine to E-Cores & Timing to P-cores ---
    for i in {1..100}; do
        ENGINE_PID=$(pgrep -u "$UID" -f "BitwigAudioEngine" | head -n1)
        if [ -n "$ENGINE_PID" ]; then
            if ps -T -p "$ENGINE_PID" -o comm 2>/dev/null | grep -q "audio-"; then
                sleep 0.5

                taskset -a -pc "$ECORES" "$ENGINE_PID" >/dev/null 2>&1

                TIMING_TIDS=$(ps -T -p "$ENGINE_PID" -o spid,comm 2>/dev/null | grep -E "data-loop|PipeWire" | awk '{print $1}')
                for tid in $TIMING_TIDS; do
                    taskset -pc "$PCORES" "$tid" >/dev/null 2>&1
                done

                for pw_tid in $(pgrep -u "$UID" -x "pipewire" | xargs -I{} ps -T -p {} -o spid,comm 2>/dev/null | grep "data-loop" | awk '{print $1}'); do
                    taskset -pc "$PCORES" "$pw_tid" >/dev/null 2>&1
                done
                break
            fi
        fi
        sleep 1
    done

    # --- Phase C: Plugin sandboxing ---
    for step in {1..100}; do
        # 1. Bitwig plugin host to E-cores
        for bph_pid in $(pgrep -u "$UID" -f "BitwigPluginHost"); do
            taskset -pc "$ECORES" "$bph_pid" >/dev/null 2>&1
        done
        break
        sleep 1
    done

    for step in {1..100}; do
        # 2. Wineserver to P-cores
        WINE_PID=$(pgrep -u "$UID" -x "wineserver" | head -n1)
        if [ -n "$WINE_PID" ]; then
            taskset -pc "$PCORES" "$WINE_PID" >/dev/null 2>&1
        fi
        break
        sleep 1
    done
) &

while pgrep -u "$UID" -x "BitwigStudio" >/dev/null 2>&1; do
    sleep 1
done