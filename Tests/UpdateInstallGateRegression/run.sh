#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
build=work/update-install-gate-regression
mkdir -p "$build"
swiftc -swift-version 6 Sources/AgentGuard/GuardState.swift Sources/AgentGuard/UpdateInstallGate.swift Tests/UpdateInstallGateRegression/Harness.swift -o "$build/regression"
"$build/regression"
