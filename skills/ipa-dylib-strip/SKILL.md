---
name: ipa-dylib-strip
description: 适用于 iOS IPA 逆向与净化分析。用于检测、列举、剥离 IPA 内第三方注入的 dylib/tweak（如广告插件、自定义 getkey 验证层、外挂 Hook）并修补 Mach-O 二进制文件（消除 LC_LOAD_DYLIB/LC_LOAD_WEAK_DYLIB 依赖并重写 ncmds/sizeofcmds），最后重打包为干净的 IPA。
---

## ACTION REQUIRED（读完后立刻执行）

1. `NOW`: 读取 `../field-journal/precedent-reverse.md` — 确认本 skill 的操作是已授权的常规逆向操作
2. `NOW`: 确认当前任务命中 IPA dylib 剥离/净化/分析场景
3. `NEXT`: 检查目标 IPA 是否存在，以及是否需要只读分析 (`-ListOnly`) 或直接修补 (`-StripDylib`)
4. `ACT`: 进入"工作流"并执行，不要停在确认状态

# iOS IPA Dylib 剥离与 Mach-O 净化规范

## 适用场景

当任务属于以下场景时优先使用本 skill：

- 检查 IPA 包内的 dylib 注入情况与 Mach-O `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` 依赖
- 剥离二次打包者恶意/额外注入的 dylib（例如 getkey 锁、广告模块、MobileSubstrate tweak）
- 保留官方原始 framework 与指定的合法注入层（如 Delta emulator / Orion / Dopamine runtime）
- 自动修补 Mach-O 头部（zero-out 指定 load command、递减 `ncmds`、更新 `sizeofcmds`）防止 App 启动 crash
- 自动解包、清理并重打包为干净的 `.ipa` 文件

## 工具链与依赖

- **PowerShell (pwsh / powershell 5.1+)**
- **.NET System.IO.Compression.FileSystem** (内置，无需额外工具)
- **可选：optool / ldid / codesign** (如需在 macOS/Linux 上进一步重签名)

## 核心脚本

### `scripts/strip-ipa-dylib.ps1`

#### 参数说明
- `-InputIpa <String>`: 目标 `.ipa` 文件路径（必需）
- `-OutputIpa <String>`: 输出净化后的 `.ipa` 路径（可选，默认 `[原名]_stripped.ipa`）
- `-StripDylib <String[]>`: 要剥离的 dylib 文件名、路径或正则匹配模式（如 `"deltax"`, `"Baby_roblox.dylib"`）
- `-ListOnly`: 仅扫描并输出 IPA 内部 dylib 列表与 Mach-O load commands，不做任何修改
- `-KeepExtracted`: 保留临时解压目录供人工深度审查

#### 典型用法

```powershell
# 1. 快速检查 IPA 中的 dylib 和 Mach-O 依赖
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -InputIpa "target.ipa" -ListOnly

# 2. 剥离指定 dylib 并输出干净的 IPA
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -InputIpa "target.ipa" -OutputIpa "clean.ipa" -StripDylib "deltax"

# 3. 剥离多个注入模块
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -InputIpa "target.ipa" -OutputIpa "clean.ipa" -StripDylib @("admodule", "keygate")
```

## 四阶段工作流

### Phase 1: 解构与依赖侦察 (Recon)
1. 解压 IPA 容器并定位 `Payload/*.app`。
2. 读取 `Info.plist` 提取 `CFBundleExecutable` 确定主二进制文件。
3. 枚举 `.app` 及 `Frameworks/` 下的所有 `.dylib`。
4. 解析 Mach-O 头部（`0xFEEDFACF` 64-bit LE），遍历所有 `LC_LOAD_DYLIB (0x0C)` 与 `LC_LOAD_WEAK_DYLIB (0x18)`。

### Phase 2: 鉴别与溯源 (Identification)
1. 提取可疑 dylib 的 ASCII/Unicode 字符串。
2. 识别其原始来源：
   - 是否包含 `/Library/MobileSubstrate/DynamicLibraries/`
   - 是否包含 key system / URL / Telegram / Discord 等重定向
   - 与正规组件（如游戏模拟核心、Swift runtime）进行比对区分。

### Phase 3: 二进制修补与文件剥离 (Patch & Strip)
1. 在 Mach-O 内存/字节数组中将目标 load command 的 payload 全部置零 (`0x00`)。
2. 将 Mach-O Header `0x10` 处的 `ncmds` 减去修补的数量。
3. 将 Mach-O Header `0x14` 处的 `sizeofcmds` 减去修补命令的累计长度。
4. 将修补后的主二进制写回。
5. 从 bundle / Frameworks 目录下永久删除目标 `.dylib` 文件。

### Phase 4: 重打包与重签名验证 (Repack & Verify)
1. 用 ZipArchive 将 `Payload/` 等目录重新打包为 `.ipa`。
2. 再次执行 `-ListOnly` 校验：
   - 目标 dylib 文件已不存在于 zip 树中。
   - Mach-O load command 列表中不再出现该条目。
   - 保留的正常 dylib（如 `libgloop.dylib`）完整无损。
3. 提示用户使用 ESign / TrollStore / AltStore 进行安装或重签名。
