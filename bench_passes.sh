#!/bin/bash
# bench_passes.sh — Build and benchmark CoreMark with each LLVM optimization
# pass applied individually (on top of -O0), recording results to CSV.
#
# Approach: compile all .c -> .ll (LLVM IR) with -O0, then run opt with each
# pass on each .ll -> .bc, then link the .bc files into an executable.
#
# Usage: ./bench_passes.sh [clang-binary] [iterations]
#   clang-binary  defaults to clang-20
#   iterations    defaults to 0 (auto-calibrate)

set -euo pipefail

CLANG="${1:-clang-20}"
OPT="${CLANG/clang/opt}"
ITERATIONS="${2:-0}"
CSV="pass_results.csv"
LOGDIR="pass_logs"
IRDIR="pass_ir"
OUTFILE="coremark.exe"

# Derive opt binary from clang (clang-20 -> opt-20)
if ! command -v "$OPT" &>/dev/null; then
    OPT="opt"
fi

mkdir -p "$LOGDIR" "$IRDIR"

# Source files (same as Makefile)
CORE_SRCS="core_list_join.c core_main.c core_matrix.c core_state.c core_util.c"
PORT_SRCS="posix/core_portme.c"
ALL_SRCS="$CORE_SRCS $PORT_SRCS"

# Compile flags (mirrors posix/core_portme.mak minus -O2)
BASE_CFLAGS="-Iposix -I. -DITERATIONS=$ITERATIONS"
LFLAGS="-lrt"

# Step 1: Compile all sources to LLVM IR once (with -O0)
compile_to_ir() {
    echo "Compiling sources to LLVM IR with -O0..."
    for src in $ALL_SRCS; do
        local base
        base=$(basename "$src" .c)
        "$CLANG" -O0 -emit-llvm -S $BASE_CFLAGS -DPERFORMANCE_RUN=1 \
            "-DFLAGS_STR=\"-O0\"" \
            "$src" -o "$IRDIR/${base}.ll" 2>&1
    done
    echo "  IR files written to $IRDIR/"
}

# Step 2: For a given pass, optimize all .ll files and link into binary
build_with_pass() {
    local pass="$1"
    local label="$2"
    local bc_files=""

    for src in $ALL_SRCS; do
        local base
        base=$(basename "$src" .c)
        local infile="$IRDIR/${base}.ll"
        local outfile="$IRDIR/${base}_opt.bc"

        if ! "$OPT" -passes="$pass" "$infile" -o "$outfile" 2>>"$LOGDIR/${label}_build.log"; then
            return 1
        fi
        bc_files="$bc_files $outfile"
    done

    # Link all optimized bitcode into final executable
    if ! "$CLANG" $bc_files -o "$OUTFILE" $LFLAGS 2>>"$LOGDIR/${label}_build.log"; then
        return 1
    fi
    return 0
}

# Extract optimization passes from opt --print-passes
get_opt_passes() {
    "$OPT" --print-passes 2>&1 | awk '
    /^Module passes:/          { section="mod"; next }
    /^Module passes with params:/ { section="skip"; next }
    /^Module analyses:/        { section="skip"; next }
    /^Module alias analyses:/  { section="skip"; next }
    /^CGSCC passes:/           { section="cgscc"; next }
    /^CGSCC passes with params:/ { section="skip"; next }
    /^CGSCC analyses:/         { section="skip"; next }
    /^Function passes:/        { section="func"; next }
    /^Function passes with params:/ { section="skip"; next }
    /^Function analyses:/      { section="skip"; next }
    /^Function alias analyses:/ { section="skip"; next }
    /^LoopNest passes:/        { section="loopnest"; next }
    /^Loop passes:/            { section="loop"; next }
    /^Loop passes with params:/ { section="skip"; next }
    /^Loop analyses:/          { section="skip"; next }
    /^Machine/                 { section="skip"; next }

    section == "skip" { next }

    /^  [a-z]/ {
        gsub(/^[[:space:]]+/, "")
        gsub(/[[:space:]]+$/, "")
        pass = $0

        # Skip non-optimization passes
        if (pass ~ /^(print|dot-|view-|verify|no-op|check-|debugify|trigger-|helloworld|instnamer|instcount|metarenamer|count-visits|invalidate)/) next
        if (pass ~ /^(annotation-remarks|declare-to-assign|name-anon-globals|pseudo-probe|insert-gcov|instrprof|instrorderfile)/) next
        if (pass ~ /^(dfsan|msan|nsan|tsan|rtsan|sancov|sanmd|asan|hwasan|tysan|kcfi|jmc)/) next
        if (pass ~ /^(ctx-instr|ctx-prof|pgo-instr|pgo-force|pgo-icall|sample-profile|memprof)/) next
        if (pass ~ /^(dxil-|hipstdpar|wasm-|win-eh|shadow-stack|objc-arc|rewrite-statepoints|rewrite-symbols)/) next
        if (pass ~ /^(embed-bitcode|pre-isel|lower-ifunc|lower-emutls|lower-global-dtors|expand-variadics)/) next
        if (pass ~ /^(gc-lowering|sjlj-eh|dwarf-eh|safe-stack|stack-protector)/) next
        if (pass ~ /^(coro-|place-safepoints|strip-gc|extract-blocks|complex-deinterleaving|interleaved-access|interleaved-load-combine)/) next
        if (pass ~ /^(assign-guid|annotation2metadata|forceattrs|canonicalize-aliases|lowertypetests|wholeprogramdevirt|cross-dso|function-import|rel-lookup-table)/) next
        if (pass ~ /^(inliner-ml|scc-oz|inliner-wrapper-no-mandatory|module-inline|global-merge-func)/) next
        if (pass ~ /^(codegenprepare|callbr-prepare|atomic-expand|scalarize-masked-mem|typepromotion)/) next

        print pass
    }
    '
}

# Standard optimization levels for comparison
STANDARD_LEVELS="default<O0> default<O1> default<O2> default<O3> default<Os> default<Oz>"

echo "pass,coremark_score,coremark_per_mhz,iterations,time_secs,status" > "$CSV"

run_one() {
    local pass="$1"
    local label="$2"
    local logfile="$LOGDIR/${label}.log"

    # Sanitize label for filenames (replace < > with _)
    local safe_label="${label//[<>]/_}"
    logfile="$LOGDIR/${safe_label}.log"

    echo "=== Building with pass: $label ==="

    # Clear previous build log
    > "$LOGDIR/${safe_label}_build.log"

    if build_with_pass "$pass" "$safe_label"; then
        # Run the benchmark
        local params="0x0 0x0 0x66 $ITERATIONS 7 1 2000"
        if ./"$OUTFILE" $params > "$logfile" 2>&1; then
            local score coremark_per_mhz iterations_out time_secs
            score=$(grep -oP 'CoreMark 1.0 : \K[0-9.]+' "$logfile" || echo "0")
            coremark_per_mhz=$(grep -oP 'CoreMark/MHz\s*:\s*\K[0-9.]+' "$logfile" || echo "0")
            iterations_out=$(grep -oP 'Iterations\s*:\s*\K[0-9]+' "$logfile" || echo "0")
            time_secs=$(grep -oP 'Total ticks\s*:\s*\K[0-9]+' "$logfile" || echo "0")

            if [ "$score" != "0" ]; then
                echo "$label,$score,$coremark_per_mhz,$iterations_out,$time_secs,ok" >> "$CSV"
                echo "  Score: $score  CoreMark/MHz: $coremark_per_mhz"
            else
                echo "$label,0,0,0,0,invalid_result" >> "$CSV"
                echo "  Invalid result (check $logfile)"
            fi
        else
            echo "$label,0,0,0,0,run_failed" >> "$CSV"
            echo "  Run failed (check $logfile)"
        fi
    else
        echo "$label,0,0,0,0,build_failed" >> "$CSV"
        echo "  Build failed (check $LOGDIR/${safe_label}_build.log)"
    fi
}

echo "Collecting LLVM optimization passes..."
PASSES=$(get_opt_passes)
NPASS=$(echo "$PASSES" | wc -l)
echo "Found $NPASS optimization passes to test"
echo "Results will be written to $CSV"
echo ""

# Compile to IR once
compile_to_ir

# Run the standard optimization levels first
for level in $STANDARD_LEVELS; do
    run_one "$level" "$level"
done

# Then run each individual pass
COUNT=0
for pass in $PASSES; do
    COUNT=$((COUNT + 1))
    echo "[$COUNT/$NPASS]"
    run_one "$pass" "$pass"
done

echo ""
echo "=== Done ==="
echo "Results saved to $CSV"
echo "Sort by score: sort -t, -k2 -rn $CSV | head -20"
