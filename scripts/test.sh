#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh server
node -e "require('node:fs').writeFileSync('build/fixture.tyr', require('./tests/record.cjs').record(31))"
for package in engine server; do
  odin test "src/$package" -vet -vet-packages:engine,server -strict-style -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false -out:"build/test-$package"
done
