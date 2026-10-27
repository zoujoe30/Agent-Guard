#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
build=work/sparkle-adapter-regression
mkdir -p "$build"
swiftc -swift-version 6 -emit-library -emit-module -module-name Sparkle Tests/SparkleAdapterRegression/SparkleStub.swift -o "$build/libSparkle.dylib" -emit-module-path "$build/Sparkle.swiftmodule"
swiftc -swift-version 6 -I "$build" -L "$build" -lSparkle -Xlinker -rpath -Xlinker "${PWD}/$build" Sources/AgentGuard/GuardState.swift Sources/AgentGuard/UpdateInstallGate.swift Sources/AgentGuard/SparkleUpdateController.swift Tests/SparkleAdapterRegression/Harness.swift -o "$build/regression"
"$build/regression"
