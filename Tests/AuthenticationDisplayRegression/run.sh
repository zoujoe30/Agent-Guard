#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
build=work/authentication-display-regression
mkdir -p "$build"
swiftc -swift-version 6 Sources/AgentGuard/AuthenticationDisplayRestorer.swift Sources/AgentGuard/AuthenticationFocusRestorer.swift Sources/AgentGuard/AuthenticationInputScope.swift Tests/AuthenticationDisplayRegression/Harness.swift -o "$build/regression"
"$build/regression"
