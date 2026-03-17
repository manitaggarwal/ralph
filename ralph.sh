#!/bin/bash

# Ralph Loop - Autonomous engineer relay
# Usage: ./ralph.sh [iterations]
# Default: runs until beads complete or max iterations

set -e

# Track claude PID so we can kill it on Ctrl-C
CLAUDE_PID=""
cleanup() {
    echo -e "\n${RED}✗${NC} Interrupted"
    [ -n "$CLAUDE_PID" ] && kill "$CLAUDE_PID" 2>/dev/null
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

    echo -e "${BLUE}› Spawning Claude engineer...${NC}"
    echo ""

    # Stream output with clean formatting.
    # Uses a FIFO so claude runs as a tracked background process. This lets
    # the trap handler kill it on Ctrl-C (bash's `read` builtin blocks signals
    # but the cleanup trap fires between reads when claude is killed).
    FIFO=$(mktemp -u /tmp/ralph-fifo-XXXXXX)
    mkfifo "$FIFO"

    claude --chrome --permission-mode acceptEdits --verbose --print "Read @RALPH.md and follow the instructions. Pick up where the last engineer left off. Complete ONE bead." --output-format stream-json > "$FIFO" 2>/dev/null &
    CLAUDE_PID=$!

    while read -r line; do
        type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        if [ "$type" = "assistant" ]; then
            # Show text
            echo "$line" | jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null | while IFS= read -r text; do
                [ -z "$text" ] && continue
                echo -e "${BLUE}▸${NC} $text"
            done
            # Show tool calls concisely: → tool_name { inputs }
            echo "$line" | jq -c '.message.content[]? | select(.type == "tool_use")' 2>/dev/null | while read -r tool; do
                [ -z "$tool" ] && continue
                name=$(echo "$tool" | jq -r '.name' 2>/dev/null)
                input=$(echo "$tool" | jq -c '.input' 2>/dev/null)
                echo -e "${YELLOW}→${NC} ${CYAN}$name${NC} ${DIM}$input${NC}"
            done
        elif [ "$type" = "user" ]; then
            # Show tool results cleanly
            echo "$line" | jq -c '.message.content[]? | select(.type == "tool_result")' 2>/dev/null | while read -r result; do
                [ -z "$result" ] && continue
                is_error=$(echo "$result" | jq -r '.is_error // false' 2>/dev/null)
                # Extract and clean content
                content=$(echo "$result" | jq -r '
                    .content |
                    if type == "array" then
                        map(select(.type == "text") | .text) | join("\n")
                    elif type == "string" then
                        .
                    else
                        "..."
                    end
                ' 2>/dev/null | tr -d '\r' | head -n 20)
                # Truncate if contains base64 image data
                if echo "$content" | grep -q '/9j/4AAQ\|data:image'; then
                    content="[image captured]"
                fi
                # Format line numbers: replace →  with spaces, dim the line numbers
                formatted=$(echo "$content" | sed -E "s/^([[:space:]]*[0-9]+)→/\x1b[2m\1\x1b[0m  /")
                if [ "$is_error" = "true" ]; then
                    echo ""
                    echo -e "${RED}✗${NC}"
                    echo -e "$formatted"
                else
                    echo ""
                    echo -e "${DIM}○${NC}"
                    echo -e "$formatted"
                fi
            done
        elif [ "$type" = "result" ]; then
            # Handle final result from Claude CLI
            subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
            result_text=$(echo "$line" | jq -r '.result // empty' 2>/dev/null)
            if [ "$subtype" = "success" ] && [ -n "$result_text" ]; then
                echo ""
                echo -e "${GREEN}✓${NC} $result_text"
            elif [ "$subtype" = "error" ]; then
                echo ""
                echo -e "${RED}✗${NC} $result_text"
            else
                echo -e "${DIM}? $line${NC}"
            fi
        elif [ "$type" != "system" ]; then
            echo -e "${DIM}? $line${NC}"
        fi
    done < "$FIFO"

    rm -f "$FIFO"
    wait "$CLAUDE_PID" 2>/dev/null || true
    CLAUDE_PID=""

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
