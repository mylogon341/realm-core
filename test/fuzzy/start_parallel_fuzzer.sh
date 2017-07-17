#!/usr/bin/env bash

SCRIPT=$(basename "${BASH_SOURCE[0]}")
DIR=$(cd "$(dirname ${BASH_SOURCE[0]})" && pwd)
ROOTDIR=$(dirname $(dirname ${DIR}))
BUILD_DIR="build_afl"

if [ "$#" -ne 2 ]; then
    echo "Usage: ${SCRIPT} <num_fuzzers> <fuzz_test>"
    echo "          num_fuzzers: the number of fuzzers to run in parallel"
    echo "          fuzz_test  : fuzz-group or fuzz-transact-log"
    exit 1
fi
num_fuzzers="$1"
fuzz_test="$2"

if [ "$(uname)" = "Darwin" ]; then
    # FIXME: Consider detecting if ReportCrash was already unloaded and skip this message
    #        or print and don't try to run AFL.
    echo "----------------------------------------------------------------------------------------"
    echo "Make sure you have unloaded the OS X crash reporter:"
    echo
    echo "launchctl unload -w /System/Library/LaunchAgents/com.apple.ReportCrash.plist"
    echo "sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.ReportCrash.Root.plist"
    echo "----------------------------------------------------------------------------------------"
else
    # FIXME: Check if AFL works if the core pattern is different, but does not start with | and test for that
    if [ "$(cat /proc/sys/kernel/core_pattern)" != "core" ]; then
        echo "----------------------------------------------------------------------------------------"
        echo "AFL might mistake crashes with hangs if the core is outputed to an external process"
        echo "Please run:"
        echo
        echo "sudo sh -c 'echo core > /proc/sys/kernel/core_pattern'"
        echo "----------------------------------------------------------------------------------------"
        exit 1
    fi
fi

echo "Building..."

cd "${DIR}/../.." || exit
rm -rf "${BUILD_DIR}"
mkdir "${BUILD_DIR}"
cd "${BUILD_DIR}" || exit
RAND_NODE_SIZE=$(python -c "import random; print (random.randint(4,999), 1000)[bool(random.randint(0,1))]")
cmake -D REALM_AFL=ON \
      -D CMAKE_C_COMPILER=afl-clang \
      -D CMAKE_CXX_COMPILER=afl-clang++ \
      -D REALM_MAX_BPNODE_SIZE="${RAND_NODE_SIZE}" \
      -D REALM_ENABLE_ENCRYPTION=ON \
      -G Ninja \
      ..
ninja "${fuzz_test}"

echo "Cleaning up the findings directory"

FINDINGS_DIR="findings"

pkill afl-fuzz
rm -rf "${FINDINGS_DIR}"
mkdir "${FINDINGS_DIR}"

# see also stop_parallel_fuzzer.sh
time_out="1000" # ms
memory="100" # MB

echo "Starting $num_fuzzers fuzzers in parallel"

# if we have only one fuzzer
if [ "$num_fuzzers" -eq 1 ]; then
    afl-fuzz -t "$time_out" \
             -m "$memory" \
             -i "${ROOTDIR}/test/fuzzy/testcases" \
             -o "${FINDINGS_DIR}" \
             "test/fuzzy/${fuzz_test}" @@
    exit 0
fi

# start the fuzzers in parallel
for i in $(seq 1 "$num_fuzzers"); do
    [[ $i -eq 1 ]] && flag="-M" || flag="-S"
    afl-fuzz -t "$time_out" \
             -m "$memory" \
             -i "${ROOTDIR}/test/fuzzy/testcases" \
             -o "${FINDINGS_DIR}" \
             "${flag}" "fuzzer$i" \
             "test/fuzzy/${fuzz_test}" @@ --name "fuzzer$i" >/dev/null 2>&1 &
done

echo
echo "Use afl-whatsup ../../${BUILD_DIR}/${FINDINGS_DIR} to check progress"
echo
