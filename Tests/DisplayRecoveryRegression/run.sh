#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
mkdir -p work/display-regression
swiftc -swift-version 6 Sources/AgentGuard/DisplayHardware.swift Sources/AgentGuard/DisplayRecovery.swift Sources/AgentGuard/DisplayBlackoutController.swift Tests/DisplayRecoveryRegression/Harness.swift -o work/display-regression/regression
work/display-regression/regression
