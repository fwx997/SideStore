# Henge 内存授权项的签名修复

Henge 的原始安装包包含增加内存上限和扩展虚拟寻址请求，但 .36 的
SideStore 最终签名只从描述文件取授权项。自定义授权项没有传给签名器；
描述文件未列出的内存请求会消失。保存续签信息时再次取描述文件，也会
丢失这些请求。

修复将主程序和每个扩展的自定义授权项，按最终包标识传给 SideSign。
仅对以下三项保留合法的 Boolean 请求：

- com.apple.developer.kernel.increased-memory-limit
- com.apple.developer.kernel.increased-debugging-memory-limit
- com.apple.developer.kernel.extended-virtual-addressing

其他受描述文件约束的授权项仍按原规则处理，应用标识和团队标识仍取自
描述文件。不会修改 Apple 签署的描述文件，也不会将主程序的内存请求
复制到所有扩展。显式关闭或删除的请求优先于旧缓存。

签名完成后重新读取每个可执行文件，核对其内存请求；若签名后丢失或值
发生变化，则报告失败。续签缓存保存的是每个可执行文件实际具有的授权项，
不再用描述文件替代。

## 构建

SideSign 子模块仍固定在 752d1ef602aa792a432ffa1e71646dc1ecf7363c。
修复以 scripts/patches/sidesign-memory-entitlements.patch 随仓库保存，
不另建依赖仓库。make build 和构建测试目标自动应用补丁。直接使用
Xcode 前先运行：

    git submodule update --init Dependencies/SideSign
    python3 scripts/apply_signing_patches.py

补丁已应用时不会重复修改；上游源码不兼容时停止构建，不强制覆盖。

## 验证

    python3 -m unittest discover -s scripts/tests -p test_memory_entitlements.py -v

回归直接编译生产签名器、权限处理器及 SideStore 的请求选择和缓存方法，
以不使用真实证书的签名后端替身记录实际发出的 XML。覆盖原始包、已丢失
权限的缓存包、主程序与扩展隔离、关闭/删除、包标识变更、五轮续签、
签名后丢失权限以及非法数据类型。

这些检查验证签名传递与续签行为；iPadOS 是否接受安装、设备是否提供额外
内存，以及 Henge 能否启动，还需真机验证。Extra memory: On 也不保证可以
分配 8 GB。首次设备回归先使用 4 GB，并检查重签后导出的 IPA 和下一轮续签。
