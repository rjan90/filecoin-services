#!/usr/bin/env bash
# 
# This script checks if any Solidity contract/library in the `service_contracts/src/` folder
# exceeds the EIP-170 contract runtime size limit (24,576 bytes)
# and the EIP-3860 init code size limit (49,152 bytes).
# 
# NEW: Now supports delta reporting when baseline sizes are provided via --baseline flag
# 
# Intended for use in CI (e.g., GitHub Actions) with Foundry.
# Exits 1 and prints the list of exceeding contracts if violations are found.
# NOTE: This script requires Bash (not sh or dash) due to use of mapfile and [[ ... ]].

set -euo pipefail

# Default values
SRC_DIR=""
BASELINE_FILE=""
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --baseline)
            BASELINE_FILE="$2"
            shift 2
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            if [[ -z "$SRC_DIR" ]]; then
                SRC_DIR="$1"
            else
                echo "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ "$SHOW_HELP" == "true" || -z "$SRC_DIR" ]]; then
    echo "Usage: $0 <contracts_source_folder> [--baseline <baseline_sizes.json>]"
    echo ""
    echo "Options:"
    echo "  --baseline <file>  Compare against baseline contract sizes for delta reporting"
    echo "  --help, -h         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 src/                                    # Basic size check"
    echo "  $0 src/ --baseline baseline_sizes.json    # Size check with delta reporting"
    exit 0
fi

command -v jq >/dev/null 2>&1 || { echo >&2 "jq is required but not installed."; exit 1; }
command -v forge >/dev/null 2>&1 || { echo >&2 "forge is required but not installed."; exit 1; }

# Gather contract and library names from service_contracts/src/
# Only matches [A-Za-z0-9_] in contract/library names (no special characters)
if [[ -d "$SRC_DIR" ]]; then
    mapfile -t contracts < <(grep -rE '^(contract|library) ' "$SRC_DIR" 2>/dev/null | sed -E 's/.*(contract|library) ([A-Za-z0-9_]+).*/\2/')
else
    contracts=()
fi

# Exit early if none found (common in empty/new projects)
if [[ ${#contracts[@]} -eq 0 ]]; then
    echo "No contracts or libraries found in $SRC_DIR."
    exit 0
fi

# cd service_contracts || { echo "Failed to change directory to service_contracts"; exit 1; }
trap 'rm -f contract_sizes.json' EXIT

# Build the contracts, get size info as JSON (ignore non-zero exit to always parse output)
echo "Building contracts and gathering size information..."
forge clean || true
forge build --sizes --json | jq . > contract_sizes.json || true

# Validate JSON output
if ! jq empty contract_sizes.json 2>/dev/null; then
    echo "forge build did not return valid JSON. Output:"
    cat contract_sizes.json
    exit 1
fi

if jq -e '. == {}' contract_sizes.json >/dev/null; then
    echo "forge did not find any contracts. forge build:"
    # This usually means build failure
    forge build
    exit 1
fi

json=$(cat contract_sizes.json)

# Filter JSON: keep only contracts/libraries from src/
json=$(echo "$json" | jq --argjson keys "$(printf '%s\n' "${contracts[@]}" | jq -R . | jq -s .)" '
  to_entries
  | map(select(.key as $k | $keys | index($k)))
  | from_entries
')

# Function to format size with color coding
format_size_change() {
    local change=$1
    local percent_change=$2
    if [[ $change -gt 0 ]]; then
        echo "🔴 +$change bytes (+${percent_change}%)"
    elif [[ $change -lt 0 ]]; then
        echo "🟢 $change bytes (${percent_change}%)"
    else
        echo "⚪ No change"
    fi
}

# Function to calculate percentage change
calc_percentage() {
    local old=$1
    local new=$2
    if [[ $old -eq 0 ]]; then
        echo "N/A"
    else
        echo "scale=1; ($new - $old) * 100 / $old" | bc -l 2>/dev/null || echo "0.0"
    fi
}

# Delta reporting if baseline provided
if [[ -n "$BASELINE_FILE" && -f "$BASELINE_FILE" ]]; then
    echo ""
    echo "📊 CONTRACT SIZE DELTA REPORT"
    echo "=============================="
    
    baseline_json=$(cat "$BASELINE_FILE")
    
    # Filter baseline JSON similarly
    baseline_json=$(echo "$baseline_json" | jq --argjson keys "$(printf '%s\n' "${contracts[@]}" | jq -R . | jq -s .)" '
      to_entries
      | map(select(.key as $k | $keys | index($k)))
      | from_entries
    ')
    
    total_runtime_delta=0
    total_init_delta=0
    changed_contracts=0
    
    echo ""
    printf "%-30s %-20s %-20s\n" "Contract" "Runtime Size Δ" "Init Code Size Δ"
    printf "%-30s %-20s %-20s\n" "--------" "---------------" "-----------------"
    
    # Compare each contract
    for contract in "${contracts[@]}"; do
        # Get current sizes (default to 0 if not found)
        current_runtime=$(echo "$json" | jq -r --arg contract "$contract" '.[$contract].runtime_size // 0')
        current_init=$(echo "$json" | jq -r --arg contract "$contract" '.[$contract].init_size // 0')
        
        # Get baseline sizes (default to 0 if not found)
        baseline_runtime=$(echo "$baseline_json" | jq -r --arg contract "$contract" '.[$contract].runtime_size // 0')
        baseline_init=$(echo "$baseline_json" | jq -r --arg contract "$contract" '.[$contract].init_size // 0')
        
        # Calculate deltas
        runtime_delta=$((current_runtime - baseline_runtime))
        init_delta=$((current_init - baseline_init))
        
        # Track totals
        total_runtime_delta=$((total_runtime_delta + runtime_delta))
        total_init_delta=$((total_init_delta + init_delta))
        
        # Count changed contracts
        if [[ $runtime_delta -ne 0 || $init_delta -ne 0 ]]; then
            ((changed_contracts++))
        fi
        
        # Calculate percentage changes
        runtime_percent=$(calc_percentage $baseline_runtime $current_runtime)
        init_percent=$(calc_percentage $baseline_init $current_init)
        
        # Format changes for display
        runtime_change=$(format_size_change $runtime_delta $runtime_percent)
        init_change=$(format_size_change $init_delta $init_percent)
        
        printf "%-30s %-35s %-35s\n" "$contract" "$runtime_change" "$init_change"
    done
    
    echo ""
    echo "📈 SUMMARY"
    echo "----------"
    echo "Changed contracts: $changed_contracts/${#contracts[@]}"
    echo "Total runtime size delta: $(format_size_change $total_runtime_delta $(calc_percentage 1 $((1 + total_runtime_delta))))"
    echo "Total init code size delta: $(format_size_change $total_init_delta $(calc_percentage 1 $((1 + total_init_delta))))"
    echo ""
fi

# Original size limit validation
echo "🔍 CHECKING SIZE LIMITS"
echo "======================"

# Find all that violate the EIP-170 runtime size limit (24,576 bytes)
exceeding_runtime=$(echo "$json" | jq -r '
  to_entries
  | map(select(.value.runtime_size > 24576))
  | .[]
  | "\(.key): \(.value.runtime_size) bytes (runtime size)"'
)

# Find all that violate the EIP-3860 init code size limit (49,152 bytes)
exceeding_initcode=$(echo "$json" | jq -r '
  to_entries
  | map(select(.value.init_size > 49152))
  | .[]
  | "\(.key): \(.value.init_size) bytes (init code size)"'
)

# Initialize status
status=0

if [[ -n "$exceeding_runtime" ]]; then
  echo "❌ ERROR: The following contracts exceed EIP-170 runtime size (24,576 bytes):"
  echo "$exceeding_runtime"
  status=1
fi

if [[ -n "$exceeding_initcode" ]]; then
  echo "❌ ERROR: The following contracts exceed EIP-3860 init code size (49,152 bytes):"
  echo "$exceeding_initcode"
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "✅ All contracts are within the EIP-170 runtime and EIP-3860 init code size limits."
fi

# Exit with appropriate status
exit $status
