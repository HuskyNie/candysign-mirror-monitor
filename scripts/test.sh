#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Sources/Metrics.swift Sources/CloudPD.swift Tests/main.swift -o build/metrics-tests
build/metrics-tests
