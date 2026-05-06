#!/bin/bash

# Ralph Loop - Autonomous engineer relay
# Usage: ./ralph.sh [iterations]
# Default: runs until beads complete or max iterations

set -e

# Track gemini PID so we can kill it on Ctrl-C
GEMINI_PID=""
cleanup() {
    echo -e "\n${RED}✗${NC} Interrupted"
    [ -n "$GEMINI_PID" ] && kill "$GEMINI_PID" 2>/dev/null
    exit 130
}
trap cleanup INT TERM

# ANSI colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m' # No colour

MAX_ITERATIONS=${1:-10}
ITERATION=0
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$PROJECT_DIR"

echo -e "${CYAN}→${NC} Starting Ralph Loop in $PROJECT_DIR"
echo "   Max iterations: $MAX_ITERATIONS"
echo ""

# Check beads are ready
if ! command -v bd &> /dev/null; then
    echo -e "${RED}✗${NC} bd (beads) not found. Install it first."
    exit 1
fi

# Show initial state
echo -e "${BLUE}▸${NC} Current beads status:"
bd ready 2>/dev/null || echo "   No beads ready or bd not initialised"
echo ""

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    # Check for dirty state - if dirty, skip fetch/pull (we're mid-work)
    if git diff --quiet && git diff --cached --quiet; then
        echo -e "${DIM}› Fetching latest changes...${NC}"
        git fetch --quiet
        git pull --rebase --quiet || true
        bd sync 2>/dev/null || true
    else
        echo -e "${YELLOW}› Dirty working tree detected - resuming previous work...${NC}"
    fi

    # Check if there are any beads to work on
    READY_COUNT=$(bd count --status open 2>/dev/null || echo "0")
    IN_PROGRESS=$(bd count --status in_progress 2>/dev/null || echo "0")

    if [ "$READY_COUNT" = "0" ] && [ "$IN_PROGRESS" = "0" ]; then
        echo -e "${DIM}○ No beads available. Waiting 20s for new work...${NC}"
        sleep 20
        continue
    fi

    ITERATION=$((ITERATION + 1))
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}▶${NC} Ralph iteration ${GREEN}$ITERATION${NC} of $MAX_ITERATIONS"
    echo "   Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${BLUE}› Spawning Gemini engineer...${NC}"
    echo ""

    # Stream output with clean formatting.
    # Uses a FIFO so gemini runs as a tracked background process. This lets
    # the trap handler kill it on Ctrl-C (bash's `read` builtin blocks signals
    # but the cleanup trap fires between reads when gemini is killed).
    FIFO=$(mktemp -u /tmp/ralph-fifo-XXXXXX)
    mkfifo "$FIFO"

    gemini --prompt "Read RALPH.md and follow the instructions. Pick up where the last engineer left off. Complete ONE bead." --approval-mode yolo --output-format stream-json > "$FIFO" 2>/dev/null &
    GEMINI_PID=$!

    LAST_WAS_MESSAGE=false
    while read -r line; do
        type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        
        if [ "$type" = "message" ]; then
            role=$(echo "$line" | jq -r '.role // empty' 2>/dev/null)
            if [ "$role" = "assistant" ]; then
                content=$(echo "$line" | jq -r '.content // empty' 2>/dev/null)
                if [ -n "$content" ] && [ "$content" != "null" ]; then
                    if [ "$LAST_WAS_MESSAGE" = false ]; then
                        printf "${BLUE}▸${NC} "
                    fi
                    printf "%s" "$content"
                    LAST_WAS_MESSAGE=true
                fi
            fi
            continue
        fi

        if [ "$LAST_WAS_MESSAGE" = true ]; then
            echo ""
            LAST_WAS_MESSAGE=false
        fi

        if [ "$type" = "tool_use" ]; then
            name=$(echo "$line" | jq -r '.tool_name' 2>/dev/null)
            input=$(echo "$line" | jq -c '.parameters' 2>/dev/null)
            echo -e "${YELLOW}→${NC} ${CYAN}$name${NC} ${DIM}$input${NC}"
        elif [ "$type" = "tool_result" ]; then
            status=$(echo "$line" | jq -r '.status' 2>/dev/null)
            output=$(echo "$line" | jq -r '.output // empty' 2>/dev/null | tr -d '\r' | head -n 20)
            if echo "$output" | grep -q '/9j/4AAQ\|data:image'; then
                output="[image captured]"
            fi
            formatted=$(echo "$output" | sed -E "s/^([[:space:]]*[0-9]+)→/\x1b[2m\1\x1b[0m  /")
            if [ "$status" = "error" ]; then
                echo ""
                echo -e "${RED}✗${NC}"
                echo -e "$formatted"
            else
                echo ""
                echo -e "${DIM}○${NC}"
                echo -e "$formatted"
            fi
        elif [ "$type" = "result" ]; then
            status=$(echo "$line" | jq -r '.status // empty' 2>/dev/null)
            if [ "$status" = "success" ]; then
                echo ""
                echo -e "${GREEN}✓${NC} Success"
            elif [ "$status" = "error" ]; then
                echo ""
                echo -e "${RED}✗${NC} Error"
            fi
        fi
    done < "$FIFO"

    rm -f "$FIFO"
    wait "$GEMINI_PID" 2>/dev/null || true
    GEMINI_PID=""

    echo ""
    echo -e "${GREEN}✓${NC} Iteration $ITERATION complete"
    echo ""
    sleep 2
done

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}■${NC} Ralph loop finished"
echo "   Total iterations: $ITERATION"
echo "   Ended: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo -e "${BLUE}▸${NC} Final beads status:"
bd ready 2>/dev/null || echo "   No beads ready"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
