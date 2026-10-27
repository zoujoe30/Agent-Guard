#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
build=work/secure-input-regression/build
mkdir -p "$build"
swiftc -swift-version 6 -emit-library -emit-module -module-name AgentGuardCore Sources/AgentGuardCore/*.swift -o "$build/libAgentGuardCore.dylib" -emit-module-path "$build/AgentGuardCore.swiftmodule"
swiftc -swift-version 6 -I "$build" -L "$build" -lAgentGuardCore -Xlinker -rpath -Xlinker "${PWD}/$build" Sources/AgentGuard/GuardController.swift Sources/AgentGuard/UpdateInstallGate.swift Sources/AgentGuard/GuardState.swift Sources/AgentGuard/SecureInputStatus.swift Tests/SecureInputRegression/Stubs.swift Tests/SecureInputRegression/Harness.swift -o "$build/regression"
"$build/regression"
# Test the actual policy with only private access relaxed in a scratch copy.
python3 - <<'PY'
from pathlib import Path
src = Path('Sources/AgentGuard/InputBlocker.swift').read_text()
assert src.count('private func shouldDrop(') == 1
Path('work/secure-input-regression/build/InputBlocker.swift').write_text(src.replace('private func shouldDrop(', 'func shouldDrop(').replace('private var spaceHandler:', 'var spaceHandler:').replace('private var activationShortcutHandler:', 'var activationShortcutHandler:').replace('private var displayShortcutHandler:', 'var displayShortcutHandler:').replace('private let inputScope', 'let inputScope'))
PY
swiftc -swift-version 6 -I "$build" -L "$build" -lAgentGuardCore -Xlinker -rpath -Xlinker "${PWD}/$build" "$build/InputBlocker.swift" Sources/AgentGuard/GuardState.swift Tests/SecureInputRegression/InputHarness.swift -o "$build/input-regression"
"$build/input-regression"
