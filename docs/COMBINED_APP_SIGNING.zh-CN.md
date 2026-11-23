# 三合一签名与更新约定

三合一保留完整 LiveContainer、SideStore、SideInstaller。siboot 负责首次安装，之后由 SideStore 接管签名与续签。首装已有效签名时无需再次安装才能使用；“我的应用 → 自签三合一”是可稍后进行的一次完整自签验证。

## 打包与更新

- 外层 Info.plist：`LCEmbeddedApps = ["SideStore", "SideInstaller"]`。
- `LCCombinedUpdateURL`：三合一 IPA 的 HTTPS 直链；不在仓库中硬编码私人发布路径。
- `LCCombinedSourceURL`：对应更新源。源中 `versions[].version`、`versions[].buildVersion` 必须与外层 `CFBundleShortVersionString`、`CFBundleVersion` 完全一致。同版本号的新构建靠 buildVersion 区分。
- 完整内容：`Frameworks/SideStoreApp.framework`、`Frameworks/SideInstallerApp.framework`、`PlugIns/LiveProcess.appex`、`PlugIns/SideInstallerLiveActivity.appex`。framework 保持原标识；扩展标识与版本跟随外层宿主。

普通自重签从当前运行的完整宿主复制输入；`context.isStoreUpdate` 的版本更新下载新包。显式导入 IPA 使用所导入的包。三合一在安装前验证 marker、两个 framework、两个必要扩展、可执行文件及版本，拒绝二合一包覆盖掉 SI；二合一仍沿用原更新路径。缓存的自定义 Info.plist 不得回写旧分发信息、版本或后台任务标识。

## 首次接管

isideload 在 SS framework 写入 `ALTCertificate.p12` 和 `ALTCertificateID`。siboot 仅向设备上的 SS 偏好写入以下交接项：

- `LCCombinedBootstrapPending`、`LCCombinedBootstrapSeeded`：首次接管状态。
- `LCCombinedBootstrapCertificateSerial`、`LCCombinedBootstrapCertificatePassword`：实际 P12 的序列号及密码，空密码有效。SS 只接受相同序列号、包含私钥的 P12；写入 Keychain 并读回成功后删除临时两项。
- 配对记录写入内置 SS 的 Documents，`isPairingReset=false`；不伪造登录会话或把旧版明文 `Account.sideconf` 送入新版加密导入流程。

可选自签在将要签名的外层 plist 写入随机 `LCCombinedSelfSignReceipt`，本地保存对应 expected receipt。只有下次读取实际运行的完整宿主、回执匹配后才清 Pending。下载、签名或安装失败均不被当作接管完成。覆盖安装使用 SS 原有退到主屏和安装元数据恢复流程。

## 并发与内存授权

SS 与 SI 在真实宿主 App Group 共用 `LCCompanionSigning.lock`。优先使用 `NSUserDefaults.lcAppGroupPath` 解析同一目录；非阻塞 `flock` 覆盖完整安装、续签和证书操作，进程内可重入。最后一个租约释放才解锁，进程退出由内核回收，不删除锁文件。另一应用忙时后台续签返回稍后重试，不跳转前台，也不记录成功。

内存 entitlement 仍以 Apple 下发 profile 为准。SS 必须在重建 App ID/profile 时重申 `INCREASED_MEMORY_LIMIT`，并保留已签选择；失去已有授权时在替换 profile 前终止。三合一宿主有授权不等于另一个独立安装的 Henge 自动获得授权。

验证命令：

```sh
python3 -m unittest discover -s scripts/tests -p test_combined_distribution.py -v
python3 -m unittest discover -s scripts/tests -p 'test_memory_*.py' -v
python3 -m unittest discover -s scripts/tests -p test_vpn_handoff.py -v
```

Swift 行为测试需要 swiftc；Windows 缺少编译器时明确跳过。仍需真机验证初装、同证书接管、自重签、更新、后台续签和两个 App 并发操作。
