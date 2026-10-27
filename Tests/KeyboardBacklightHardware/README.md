此测试会实际关闭并恢复内置键盘背光，不接入默认 test.sh。
在应用未托管且没有待恢复记录时手动编译运行：

```
swiftc -swift-version 6 Sources/AgentGuard/KeyboardBacklightController.swift Tests/KeyboardBacklightHardware/Harness.swift -o /tmp/agentguard-keyboard-test
/tmp/agentguard-keyboard-test
/tmp/agentguard-keyboard-test --crash
```

最后一条会SIGKILL测试主进程，独立子进程应恢复原亮度/自动设置并清除恢复记录。SIGKILL用例需另外读回硬件和恢复文件，不以进程137退出码作为通过证据。
