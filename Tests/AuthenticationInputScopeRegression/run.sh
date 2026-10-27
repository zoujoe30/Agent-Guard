#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
build=work/authentication-input-scope-regression
mkdir -p "$build"
swiftc -swift-version 6 Sources/AgentGuard/AuthenticationInputScope.swift Tests/AuthenticationInputScopeRegression/Harness.swift -o "$build/regression"
"$build/regression"
