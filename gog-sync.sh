#!/bin/bash
# Usage: ./gog-sync.sh [--download] [--download-all] [--repair] [--tty] [--show-all-output] [--game-name <name>] [--exact-match]



log_file="gog-sync.log"
cd ~/gog-archive

# High-precision start time (nanoseconds)
start_time_ns=$(date +%s%N)
start_time_fmt=$(date +"%m/%d/%Y %H:%M:%S")

DOWNLOAD_DIR="/downloads"
THREADS="8"

DOWNLOAD_FLAG=""
DOWNLOAD_ALL=false
REPAIR_FLAG=""
LIST_ALL=false
TTY_FLAG=""
SHOW_ALL_OUTPUT=false
VERBOSE_LOG=false
GAME_NAME=""
EXACT_MATCH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --download-all)
            DOWNLOAD_ALL=true
            ;;
        --download)
            DOWNLOAD_FLAG="--download"
            ;;
        --repair)
            REPAIR_FLAG="--repair"
            ;;
        --list-all)
            LIST_ALL=true
            ;;
        --tty)
            TTY_FLAG="-t"
            ;;
        --show-all-output)
            SHOW_ALL_OUTPUT=true
            ;;
        --verbose-log)
            VERBOSE_LOG=true
            ;;
        --game-name)
            shift
            GAME_NAME="$1"
            ;;
        --exact-match)
            EXACT_MATCH=true
            ;;
    esac
    shift
done

# Determine mode for logging (after parsing)
if [ "$LIST_ALL" = true ]; then
    MODE="ListAll"
elif [ "$DOWNLOAD_ALL" = true ]; then
    MODE="DownloadAll"
elif [ -n "$DOWNLOAD_FLAG" ]; then
    MODE="Download"
elif [ -n "$REPAIR_FLAG" ]; then
    MODE="Repair"
else
    MODE="ListUpdated"
fi

# Append a timestamped line to the log file
log_line() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$log_file"; }

# Run header — only emit lines for active/non-default values
header_lines=("==== GOG Sync Run Start: $start_time_fmt ====" "Mode: $MODE")
[ -n "$GAME_NAME" ] && header_lines+=("Game: ${GAME_NAME}$([ "$EXACT_MATCH" = true ] && echo ' (exact)')")
[ "$SHOW_ALL_OUTPUT" = true ] && header_lines+=("ShowAllOutput: true")
[ "$VERBOSE_LOG" = true ]     && header_lines+=("VerboseLog: true")
[ -n "$TTY_FLAG" ]            && header_lines+=("TTY: true")
for line in "${header_lines[@]}"; do
    echo "$line"
    log_line "$line"
done

# Build lgogdownloader command
GAME_ARG=""
if [ -n "$GAME_NAME" ]; then
    if [ "$EXACT_MATCH" = true ]; then
        GAME_ARG="--game ^${GAME_NAME}$"
    else
        GAME_ARG="--game ${GAME_NAME}"
    fi
fi
if [ "$LIST_ALL" = true ]; then
    LGOG_COMMAND="lgogdownloader --list $GAME_ARG --directory /downloads --threads 8"
elif [ "$DOWNLOAD_ALL" = true ]; then
    LGOG_COMMAND="lgogdownloader --download $GAME_ARG --directory /downloads --threads 8"
elif [ -n "$DOWNLOAD_FLAG" ]; then
    LGOG_COMMAND="lgogdownloader --download --updated $GAME_ARG --directory /downloads --threads 8"
elif [ -n "$REPAIR_FLAG" ]; then
    LGOG_COMMAND="lgogdownloader --repair --download $GAME_ARG --directory /downloads --threads 8"
else
    LGOG_COMMAND="lgogdownloader --list --updated $GAME_ARG --directory /downloads --threads 8"
fi

log_line "Running command: docker-compose run --rm ${TTY_FLAG} gogrepo ${LGOG_COMMAND}"

# Temp files survive the pipeline subshell — used for counters and throttle state
counter_file=$(mktemp)
last_total_file=$(mktemp)
echo "0 0 0" > "$counter_file"
echo "0" > "$last_total_file"

if [[ "$LGOG_COMMAND" == *"--list"* ]]; then
    # List mode: show everything on console and log (no TUI progress blocks in list output)
    docker-compose run --rm $TTY_FLAG gogrepo $LGOG_COMMAND 2>&1 \
        | sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
        | grep -v -E 'Getting product data|Getting game names|Getting game info|^\s*$' \
        | while IFS= read -r line; do
            echo "$line"
            log_line "$line"
        done
elif [ "$SHOW_ALL_OUTPUT" = true ]; then
    # Console: show all output after basic noise filtering
    # Log: same but TUI progress blocks (thread status + progress bars + Total lines) are excluded
    docker-compose run --rm $TTY_FLAG gogrepo $LGOG_COMMAND 2>&1 \
        | sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
        | grep -v -E 'Getting product data|Getting game names|Getting game info|^\s*$' \
        | while IFS= read -r line; do
            echo "$line"
            if ! [[ "$line" =~ ^#[0-9]+[[:space:]] ]] && \
               ! [[ "$line" =~ ^[[:space:]]*[0-9]+%[[:space:]] ]] && \
               ! [[ "$line" =~ ^Total: ]]; then
                log_line "$line"
            fi
            read -r cc ec wc < "$counter_file"
            if [[ "$line" == *"Download complete:"* ]] || [[ "$line" == *"Repairing file:"* ]]; then
                cc=$((cc+1)); echo "$cc $ec $wc" > "$counter_file"
            elif [[ "${line,,}" == *"error"* ]]; then
                ec=$((ec+1)); echo "$cc $ec $wc" > "$counter_file"
            elif [[ "${line,,}" == *"warning"* ]]; then
                wc=$((wc+1)); echo "$cc $ec $wc" > "$counter_file"
            fi
        done
else
    # Default mode (--verbose-log also uses this path):
    # Console: file completions, throttled Total heartbeat (~30s), errors, warnings
    # Log: errors, warnings, and file completion events only
    docker-compose run --rm $TTY_FLAG gogrepo $LGOG_COMMAND 2>&1 \
        | sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' \
        | tr -d '\r' \
        | grep -v -E 'Getting product data|Getting game names|Getting game info|^\s*$' \
        | while IFS= read -r line; do
            ts="[$(date '+%H:%M:%S')]"
            read -r cc ec wc < "$counter_file"
            if [[ "$line" == *"Download complete:"* ]] || [[ "$line" == *"Repairing file:"* ]]; then
                echo "$ts $line"
                echo "$line" >> "$log_file"
                cc=$((cc+1)); echo "$cc $ec $wc" > "$counter_file"
            elif [[ "$line" =~ ^#0([[:space:]]|:) ]]; then
                # Start of a new TUI block — reset accumulator
                tui_block=("$line")
            elif [[ ${#tui_block[@]} -gt 0 ]] && ! [[ "$line" =~ ^Total: ]]; then
                # Inside a TUI block — accumulate thread header/progress lines
                tui_block+=("$line")
            elif [[ "$line" =~ ^Total: ]]; then
                last_ts=$(< "$last_total_file")
                now_ts=$(date +%s)
                if (( now_ts - last_ts >= 30 )) && [[ ${#tui_block[@]} -gt 0 ]]; then
                    echo "$ts --- TUI Status Snapshot ---"
                    printf '%s\n' "${tui_block[@]}"
                    echo "$line"
                    echo "------------------"
                    echo "$now_ts" > "$last_total_file"
                fi
                tui_block=()
            elif [[ "${line,,}" == *"error"* ]]; then
                echo "$ts [ERROR] $line"
                log_line "[ERROR] $line"
                ec=$((ec+1)); echo "$cc $ec $wc" > "$counter_file"
            elif [[ "${line,,}" == *"warning"* ]]; then
                echo "$ts [WARN] $line"
                log_line "[WARN] $line"
                wc=$((wc+1)); echo "$cc $ec $wc" > "$counter_file"
            fi
        done
fi


# Read counters (written by the pipeline subshell via temp files)
read -r complete_count error_count warn_count < "$counter_file" 2>/dev/null \
    || { complete_count=0; error_count=0; warn_count=0; }
rm -f "$counter_file" "$last_total_file"

end_time_ns=$(date +%s%N)
end_time_fmt=$(date +"%m/%d/%Y %H:%M:%S")
elapsed_ns=$((end_time_ns - start_time_ns))
elapsed_sec=$((elapsed_ns / 1000000000))
elapsed_ms=$(( (elapsed_ns / 1000000) % 1000 ))
elapsed_hr=$((elapsed_sec / 3600))
elapsed_min=$(( (elapsed_sec % 3600) / 60 ))
elapsed_s=$((elapsed_sec % 60))
elapsed_fmt=$(printf "%02d:%02d:%02d.%03d" $elapsed_hr $elapsed_min $elapsed_s $elapsed_ms)

summary_line="==== Summary: ${complete_count} file(s) completed, ${error_count} error(s), ${warn_count} warning(s) ===="
end_line="==== GOG Sync Run End: $end_time_fmt (Elapsed: $elapsed_fmt) ===="
echo "$summary_line"; log_line "$summary_line"
echo "$end_line";     log_line "$end_line"