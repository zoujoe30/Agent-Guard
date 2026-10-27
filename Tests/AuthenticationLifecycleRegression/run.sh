#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
build=work/authentication-lifecycle-regression
mkdir -p "$build"
swiftc -swift-version 6 Sources/AgentGuard/AuthenticationController.swift Tests/AuthenticationLifecycleRegression/Harness.swift -o "$build/regression"
"$build/regression"
