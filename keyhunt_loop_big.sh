#!/bin/bash

# Trap Ctrl+C to exit gracefully
trap 'echo -e "\n🛑 Script interrupted. Cleaning up..."; cleanup; exit 1' INT TERM

# Cleanup function to kill any remaining processes
cleanup() {
    if [[ -n $CURRENT_PID ]]; then
        echo "🧹 Cleaning up PID: $CURRENT_PID"
        sudo kill -9 $CURRENT_PID 2>/dev/null
        wait $CURRENT_PID 2>/dev/null
    fi
    stop_log_tail
    finalize_current_run
    [[ $(type -t update_tracker) == "function" ]] && update_tracker
}

# Configuration
TIMEOUT=420  # 10 minutes in seconds
PROGRESS_INTERVAL=60
RANGE_FILES=(
    "ranges_part1.txt"
    "ranges_part2.txt"
    "ranges_part3.txt"
    "ranges_part4.txt"
)
TRACK_FILE="range_tracker.txt"
LOG_DIR="keyhunt_loop_big_logs"
RANGES=()
RANGE_SOURCE_FILES=()
RANGE_SOURCE_LINES=()
CURRENT_PID=""
CURRENT_TAIL_PID=""
CURRENT_LOG_FILE=""
CURRENT_RANGE=""
CURRENT_RANGE_FILE=""
CURRENT_RANGE_LINE=""
LAST_RANGE_REMOVED=0

normalize_hex() {
    local value=${1#0x}
    value=${value,,}
    while [[ ${#value} -gt 1 && ${value:0:1} == "0" ]]; do
        value=${value:1}
    done
    [[ -n $value ]] || value="0"
    printf '%s\n' "$value"
}

hex_ge() {
    local left right
    left=$(normalize_hex "$1")
    right=$(normalize_hex "$2")

    if (( ${#left} > ${#right} )); then
        return 0
    fi
    if (( ${#left} < ${#right} )); then
        return 1
    fi
    [[ $left == "$right" || $left > $right ]]
}

replace_range_line() {
    local range_file=$1
    local line_number=$2
    local replacement=$3
    local temp_file

    temp_file=$(mktemp)
    awk -v target="$line_number" -v text="$replacement" 'NR == target { $0 = text } { print }' "$range_file" > "$temp_file"
    mv "$temp_file" "$range_file"
}

stop_log_tail() {
    if [[ -n $CURRENT_TAIL_PID ]] && kill -0 "$CURRENT_TAIL_PID" 2>/dev/null; then
        kill "$CURRENT_TAIL_PID" 2>/dev/null
        wait "$CURRENT_TAIL_PID" 2>/dev/null
    fi
    CURRENT_TAIL_PID=""
}

persist_dance_progress() {
    local log_file=$1
    local original_range=$2
    local range_file=$3
    local range_line=$4
    local progress_line low high new_range

    LAST_RANGE_REMOVED=0

    if [[ ! -f $log_file ]]; then
        return
    fi

    progress_line=$(grep 'BSGS_PROGRESS mode=dance' "$log_file" | tail -n 1)
    if [[ -z $progress_line ]]; then
        echo "ℹ️  No dance progress marker found for $original_range"
        return
    fi

    if [[ $progress_line =~ low=0x([[:xdigit:]]+)[[:space:]]+high=0x([[:xdigit:]]+) ]]; then
        low=${BASH_REMATCH[1]}
        high=${BASH_REMATCH[2]}
    else
        echo "⚠️  Could not parse dance progress line: $progress_line"
        return
    fi

    if hex_ge "$low" "$high"; then
        echo "✅ Range exhausted, removing from rotation: $original_range"
        replace_range_line "$range_file" "$range_line" "# exhausted $original_range"
        LAST_RANGE_REMOVED=1
        return
    fi

    new_range="${low}:${high}"
    if [[ $new_range == "$original_range" ]]; then
        echo "ℹ️  Range unchanged after this run: $original_range"
        return
    fi

    echo "📝 Narrowed range: $original_range -> $new_range"
    replace_range_line "$range_file" "$range_line" "$new_range"
}

finalize_current_run() {
    if [[ -n $CURRENT_LOG_FILE && -n $CURRENT_RANGE && -n $CURRENT_RANGE_FILE && -n $CURRENT_RANGE_LINE ]]; then
        persist_dance_progress "$CURRENT_LOG_FILE" "$CURRENT_RANGE" "$CURRENT_RANGE_FILE" "$CURRENT_RANGE_LINE"
    fi
    if [[ -n $CURRENT_LOG_FILE && -f $CURRENT_LOG_FILE ]]; then
        rm -f "$CURRENT_LOG_FILE"
    fi

    CURRENT_PID=""
    CURRENT_LOG_FILE=""
    CURRENT_RANGE=""
    CURRENT_RANGE_FILE=""
    CURRENT_RANGE_LINE=""
}

load_ranges() {
    RANGES=()
    RANGE_SOURCE_FILES=()
    RANGE_SOURCE_LINES=()
    for range_file in "${RANGE_FILES[@]}"; do
        if [[ ! -f $range_file ]]; then
            echo "❌ Missing range file: $range_file" >&2
            exit 1
        fi
        local line_number=0
        local range_line
        while IFS= read -r range_line || [[ -n $range_line ]]; do
            ((line_number++))
            range_line=${range_line%$'\r'}
            if [[ -z ${range_line//[[:space:]]/} || ${range_line:0:1} == "#" ]]; then
                continue
            fi
            RANGES+=("$range_line")
            RANGE_SOURCE_FILES+=("$range_file")
            RANGE_SOURCE_LINES+=("$line_number")
        done < "$range_file"
    done
}

load_state() {
    if [[ -f $TRACK_FILE ]]; then
        local saved
        saved=$(<"$TRACK_FILE")
        if [[ $saved =~ ^[0-9]+$ ]]; then
            range_index=$saved
        fi
    fi
    if (( total_ranges == 0 )); then
        echo "❌ No ranges loaded" >&2
        exit 1
    fi
    (( range_index %= total_ranges ))
}

update_tracker() {
    echo "$range_index" > "$TRACK_FILE"
}

load_ranges
total_ranges=${#RANGES[@]}
range_index=0
load_state
update_tracker
mkdir -p "$LOG_DIR"


# Main loop

echo "🚀 Starting keyhunt range cycling script"
echo "📊 Total ranges: $total_ranges"
echo "⏱️  Time per range: $TIMEOUT seconds"
echo "📝 Progress capture interval: $PROGRESS_INTERVAL seconds"
echo "🔄 Press Ctrl+C to stop gracefully"
echo "======================================"

while true; do
    update_tracker
    current_range=${RANGES[$range_index]}
    current_range_file=${RANGE_SOURCE_FILES[$range_index]}
    current_range_line=${RANGE_SOURCE_LINES[$range_index]}
    CURRENT_RANGE=$current_range
    CURRENT_RANGE_FILE=$current_range_file
    CURRENT_RANGE_LINE=$current_range_line
    CURRENT_LOG_FILE="$LOG_DIR/range_${range_index}_$(date +%Y%m%d_%H%M%S).log"
    
    echo "🎯 [$(date)] Range $((range_index + 1))/$total_ranges: $current_range"
    echo "📄 Source: ${current_range_file}:${current_range_line}"
    echo "📄 Log: $CURRENT_LOG_FILE"
    echo "🚀 Launching keyhunt..."
    
    # Run in quiet mode so only periodic stats and BSGS_PROGRESS lines hit the log.
    sudo ./keyhunt -m bsgs -f tests/135.txt -r "$current_range" -B dance -q -s "$PROGRESS_INTERVAL" -S -k 420 -t 2 -l compress > "$CURRENT_LOG_FILE" 2>&1 &
    CURRENT_PID=$!
    tail --pid="$CURRENT_PID" -n +1 -f "$CURRENT_LOG_FILE" &
    CURRENT_TAIL_PID=$!
    
    echo "sPid: $CURRENT_PID"
    echo "------------------------------"
    
    # Wait for timeout period, checking if process is still alive
    elapsed=0
    while [[ $elapsed -lt $TIMEOUT ]]; do
        if ! kill -0 $CURRENT_PID 2>/dev/null; then
            echo "⚠️  Process ended early"
            break
        fi
        sleep 1
        ((elapsed++))
        
        # Show progress every 30 seconds
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            echo "⏳ Elapsed: ${elapsed}s/${TIMEOUT}s"
        fi
    done
    
    # Try graceful termination first
    if kill -0 $CURRENT_PID 2>/dev/null; then
        echo "🛑 Time's up! Sending SIGINT to PID: $CURRENT_PID"
        sudo kill -INT $CURRENT_PID 2>/dev/null
        
        # Wait up to 10 seconds for graceful shutdown
        wait_count=0
        while [[ $wait_count -lt 10 ]] && kill -0 $CURRENT_PID 2>/dev/null; do
            sleep 1
            ((wait_count++))
        done
        
        # Force kill if still running
        if kill -0 $CURRENT_PID 2>/dev/null; then
            echo "💀 Force killing PID: $CURRENT_PID"
            sudo kill -9 $CURRENT_PID 2>/dev/null
            sleep 2
        fi
        
        # Clean up zombie process
        wait $CURRENT_PID 2>/dev/null
    fi

    stop_log_tail
    finalize_current_run
    load_ranges
    total_ranges=${#RANGES[@]}
    if (( total_ranges == 0 )); then
        echo "✅ All ranges have been exhausted"
        exit 0
    fi
    
    echo "✅ Completed range: $current_range"
    echo "======================================"
    
    # Move to next range (circular)
    if (( LAST_RANGE_REMOVED )); then
        ((range_index %= total_ranges))
    else
        ((range_index = (range_index + 1) % total_ranges))
    fi
    
    # Brief pause between ranges
    sleep 2
done