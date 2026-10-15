#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -parse-as-library \
  Sources/Tendedero/LineRetractionDelay.swift Tests/LineRetractionDelayChecks.swift \
  -o .build/retraction-delay-checks
.build/retraction-delay-checks
