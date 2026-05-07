#!/bin/bash

# Ralph Loop - Autonomous engineer relay
# Usage: ./ralph.sh [iterations]
# Default: runs until beads complete or max iterations

set -e

# Track opencode PID so we can kill it on Ctrl-C
OPENCODE_PID=""
cleanup() {
    echo -e "\n${RED}✗${NC} Interrupted"
    [ -n "$OPENCODE_PID" ] && kill "$OPENCODE_PID" 2>/dev/null
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

    echo -e "${BLUE}› Spawning opencode engineer...${NC}"
    echo ""

    # Stream output with clean formatting.
    # Uses a FIFO so opencode runs as a tracked background process. This lets
    # the trap handler kill it on Ctrl-C (bash's `read` builtin blocks signals
    # but the cleanup trap fires between reads when opencode is killed).
    FIFO=$(mktemp -u /tmp/ralph-fifo-XXXXXX)
    mkfifo "$FIFO"

    opencode run "Read @RALPH.md and follow the instructions. Pick up where the last engineer left off. Complete ONE bead." --format json --dangerously-skip-permissions > "$FIFO" 2>/dev/null &
    OPENCODE_PID=$!

    while read -r line; do
        type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        if [ "$type" = "text" ]; then
            text=$(echo "$line" | jq -r '.part.text // empty' 2>/dev/null)
            [ -z "$text" ] && continue
            echo -e "${BLUE}▸${NC} $text"
        elif [ "$type" = "tool_use" ]; then
            name=$(echo "$line" | jq -r '.part.tool // empty' 2>/dev/null)
            status=$(echo "$line" | jq -r '.part.state.status // empty' 2>/dev/null)
            input=$(echo "$line" | jq -c '.part.state.input // empty' 2>/dev/null)
            echo -e "${YELLOW}→${NC} ${CYAN}$name${NC} ${DIM}$input${NC}"
            if [ "$status" = "completed" ] || [ "$status" = "error" ]; then
                output=$(echo "$line" | jq -r '.part.state.output // empty' 2>/dev/null | head -n 20)
                if [ -n "$output" ]; then
                    if echo "$output" | grep -q '/9j/4AAQ\|data:image'; then
                        output="[image captured]"
                    fi
                    formatted=$(echo "$output" | sed -E "s/^([[:space:]]*[0-9]+)→/\x1b[2m\1\x1b[0m  /")
                    if [ "$status" = "error" ]; then
                        echo -e "${RED}✗${NC}"
                    else
                        echo -e "${DIM}○${NC}"
                    fi
                    echo -e "$formatted"
                fi
            fi
        elif [ "$type" = "step_finish" ]; then
            reason=$(echo "$line" | jq -r '.part.reason // empty' 2>/dev/null)
            if [ "$reason" = "stop" ]; then
                echo ""
                echo -e "${GREEN}✓${NC} Step complete"
            fi
        fi
    done < "$FIFO"

    rm -f "$FIFO"
    wait "$OPENCODE_PID" 2>/dev/null || true
    OPENCODE_PID=""

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
