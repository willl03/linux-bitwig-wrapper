#!/bin/bash
# ==============================================================================
# Bitwig Studio Thread & Core Placement Audit
# ==============================================================================

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_header() {
    echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"
    printf "%-8s %-8s %-6s %-6s %-8s %-16s %-22s\n" "PID" "TID" "PSR" "CLS" "RTPRIO" "AFFINITY" "COMMAND"
    echo "--------------------------------------------------------------------------------"
}

audit_thread() {
    local pid="$1"
    local tid="$2"
    local comm="$3"
    
    # Verify the thread actually exists in /proc
    if [ ! -d "/proc/$pid/task/$tid" ]; then
        return
    fi

    # Read current executing CPU core (field 39 of /proc/[pid]/task/[tid]/stat)
    local psr
    psr=$(awk '{print $39}' "/proc/$pid/task/$tid/stat" 2>/dev/null)
    [[ -z "$psr" || ! "$psr" =~ ^[0-9]+$ ]] && psr="-"

    # Read scheduling policy (CLS) and real-time priority (RTPRIO)
    local sched_info
    sched_info=$(chrt -p "$tid" 2>/dev/null)
    local cls="-"
    local rtprio="-"
    if [ -n "$sched_info" ]; then
        if echo "$sched_info" | grep -q "SCHED_FIFO"; then cls="FF"; fi
        if echo "$sched_info" | grep -q "SCHED_OTHER"; then cls="TS"; fi
        if echo "$sched_info" | grep -q "SCHED_BATCH"; then cls="B"; fi
        if echo "$sched_info" | grep -q "SCHED_IDLE"; then cls="IDL"; fi
        rtprio=$(echo "$sched_info" | grep "current priority:" | awk '{print $NF}')
    fi

    # Read allowed taskset affinity mask list
    local affinity
    affinity=$(taskset -cp "$tid" 2>/dev/null | awk -F': ' '{print $2}')
    [ -z "$affinity" ] && affinity="-"

    # Color code PSR (0=IRQ, 1-5=P-Core, 6-13=E-Core, 14-15=LPE)
    local psr_color="$NC"
    if [[ "$psr" =~ ^[0-9]+$ ]]; then
        if (( psr >= 1 && psr <= 5 )); then
            psr_color="$GREEN"   # P-Core
        elif (( psr >= 6 && psr <= 13 )); then
            psr_color="$YELLOW"  # E-Core
        elif (( psr == 0 )); then
            psr_color="$RED"     # Core 0 (Collision with IRQs)
        else
            psr_color="$RED"     # Core 14-15 (SoC Low-Power Island)
        fi
    fi

    printf "%-8s %-8s ${psr_color}%-6s${NC} %-6s %-8s %-16s %-22s\n" \
        "$pid" "$tid" "$psr" "$cls" "$rtprio" "$affinity" "$comm"
}

# ------------------------------------------------------------------------------
# 1. Main Process & GUI Renderers
# ------------------------------------------------------------------------------
print_header "1. BITWIG MAIN PROCESS & GUI THREADS"
MAIN_PID=$(pgrep -u "$UID" -x "BitwigStudio" | head -n1)
if [ -n "$MAIN_PID" ]; then
    audit_thread "$MAIN_PID" "$MAIN_PID" "BitwigStudio (Main)"
    for tid in $(ps -T -p "$MAIN_PID" -o spid,comm 2>/dev/null | grep -E "X11Render|swapchain|Paint|Event thread" | awk '{print $1}'); do
        comm=$(cat "/proc/$MAIN_PID/task/$tid/comm" 2>/dev/null || echo "gui-thread")
        audit_thread "$MAIN_PID" "$tid" "$comm"
    done
else
    echo "BitwigStudio process not found."
fi

# ------------------------------------------------------------------------------
# 2. JVM JIT Compilers & Garbage Collectors
# ------------------------------------------------------------------------------
print_header "2. JVM COMPILERS & ZGC WORKERS"
if [ -n "$MAIN_PID" ]; then
    for tid in $(ps -T -p "$MAIN_PID" -o spid,comm 2>/dev/null | grep -E "Compiler|ZWorker|ZDriver" | awk '{print $1}'); do
        comm=$(cat "/proc/$MAIN_PID/task/$tid/comm" 2>/dev/null || echo "jvm-worker")
        audit_thread "$MAIN_PID" "$tid" "$comm"
    done
else
    echo "BitwigStudio process not found."
fi

# ------------------------------------------------------------------------------
# 3. Audio Engine & Real-Time DSP Workers
# ------------------------------------------------------------------------------
print_header "3. AUDIO ENGINE & DSP WORKERS (audio-*)"
ENGINE_PID=$(pgrep -u "$UID" -f "BitwigAudioEngine" | head -n1)
if [ -n "$ENGINE_PID" ]; then
    audit_thread "$ENGINE_PID" "$ENGINE_PID" "BitwigAudioEngine (Main)"
    for tid in $(ps -T -p "$ENGINE_PID" -o spid,comm 2>/dev/null | grep -E "audio-[0-9]+" | awk '{print $1}'); do
        comm=$(cat "/proc/$ENGINE_PID/task/$tid/comm" 2>/dev/null || echo "audio-dsp")
        audit_thread "$ENGINE_PID" "$tid" "$comm"
    done
else
    echo "BitwigAudioEngine process not found."
fi

# ------------------------------------------------------------------------------
# 4. Driver Timings (PipeWire & data-loop)
# ------------------------------------------------------------------------------
print_header "4. HARDWARE TIMING LOOPS (PipeWire & data-loop)"
if [ -n "$ENGINE_PID" ]; then
    for tid in $(ps -T -p "$ENGINE_PID" -o spid,comm 2>/dev/null | grep -E "data-loop|PipeWire" | awk '{print $1}'); do
        comm=$(cat "/proc/$ENGINE_PID/task/$tid/comm" 2>/dev/null || echo "engine-timing")
        audit_thread "$ENGINE_PID" "$tid" "$comm"
    done
fi
for pw_pid in $(pgrep -u "$UID" -x "pipewire"); do
    for tid in $(ps -T -p "$pw_pid" -o spid,comm 2>/dev/null | grep -E "data-loop|pipewire" | awk '{print $1}'); do
        comm=$(cat "/proc/$pw_pid/task/$tid/comm" 2>/dev/null || echo "pipewire")
        audit_thread "$pw_pid" "$tid" "PW:$comm"
    done
done

# ------------------------------------------------------------------------------
# 5. Bitwig Plugin Hosts
# ------------------------------------------------------------------------------
print_header "5. BITWIG PLUGIN HOSTS"
BPH_PIDS=$(pgrep -u "$UID" -f "BitwigPluginHost")
if [ -n "$BPH_PIDS" ]; then
    for bph in $BPH_PIDS; do
        audit_thread "$bph" "$bph" "BitwigPluginHost"
        for tid in $(ps -T -p "$bph" -o spid,comm 2>/dev/null | grep -E "remote-p|PluginsThread" | head -n2 | awk '{print $1}'); do
            comm=$(cat "/proc/$bph/task/$tid/comm" 2>/dev/null || echo "host-worker")
            audit_thread "$bph" "$tid" "$comm"
        done
    done
else
    echo "No BitwigPluginHost processes running."
fi

# ------------------------------------------------------------------------------
# 6. Wine & yabridge
# ------------------------------------------------------------------------------
print_header "6. WINESERVER, WINEDEVICE & YABRIDGE"
WINE_PIDS=$(pgrep -u "$UID" -f "wineserver|winedevice.exe|yabridge-host")
if [ -n "$WINE_PIDS" ]; then
    for wpid in $WINE_PIDS; do
        pname=$(cat "/proc/$wpid/comm" 2>/dev/null || echo "wine-proc")
        audit_thread "$wpid" "$wpid" "$pname (Root)"
        for tid in $(ps -T -p "$wpid" -o spid,comm 2>/dev/null | grep -E "audio-0|worker" | awk '{print $1}'); do
            comm=$(cat "/proc/$wpid/task/$tid/comm" 2>/dev/null || echo "wine-thread")
            audit_thread "$wpid" "$tid" "$comm"
        done
    done
else
    echo "No Wine or yabridge processes active."
fi
echo ""