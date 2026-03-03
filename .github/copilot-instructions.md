## 构建和部署规范

**所有构建和推送操作必须通过 `.\Acode\scripts/hdc-debug/deploy.ps1` 脚本执行，禁止手动 hdc/gradle 命令。**

### 常用命令

```powershell
# 完整流程：rspack 前端构建 + Gradle APK + 推送 + 调试服务器
.\Acode\scripts\hdc-debug\deploy.ps1 -Action full

# 仅 Gradle 构建 + 推送（跳过 rspack，适合只改了脚本/Java/assets）
.\Acode\scripts\hdc-debug\deploy.ps1 -Action bp

# 仅推送已构建的 APK
.\Acode\scripts\hdc-debug\deploy.ps1 -Action push

# 启动调试服务器（LAN 模式，不用 rport）
.\Acode\scripts\hdc-debug\deploy.ps1 -Action server
```

### 目标设备

- 华为 HarmonyOS + 卓易通 Android 兼容层
- HDC 设备 ID: `2PM0223B21002707`
- 卓易通网络隔离：127.0.0.1 不与 HarmonyOS 宿主共享，rport 无效
- 可用调试通道：LAN IP `ws://192.168.1.2:8092`（需 Scheme=http）