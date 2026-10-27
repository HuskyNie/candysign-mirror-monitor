#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" Sources/Metrics.swift Sources/CloudPD.swift Sources/PortDetail.swift Tests/UI/main.swift -o build/detail-ui-tests
build/detail-ui-tests
