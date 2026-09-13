---
name: ipa-dylib-strip
description: 适用于 iOS IPA 逆向与净化分析。用于检测、列举、剥离 IPA 内第三方注入的 dylib/tweak（如广告插件、自定义 getkey 验证层、外挂 Hook、Phong Roblox 等）并修补 Mach-O 二进制文件（消除 LC_LOAD_DYLIB/LC_LOAD_WEAK_DYLIB 依赖、内存平移并重写 ncmds/sizeofcmds），最后重打包为干净的 IPA。
---

## ACTION REQUIRED（读完后立刻执行）

1. `NOW`: 读取 `../field-journal/precedent-reverse.md` — 确认本 skill 的操作是已授权的常规逆向操作
2. `NOW`: 确认当前任务命中 IPA dylib 剥离/净化/分析场景（或 Phong Roblox iOS 等二次打包净化）
3. `NEXT`: 检查目标 IPA 是否存在或提供下载 URL，确定分析 (`-ListOnly`)、通用剥离 (`-StripDylib`) 或预设净化 (`-Preset phong-roblox`)
4. `ACT`: 进入"工作流"并执行，不要停在确认状态

# iOS IPA Dylib 剥离与 Mach-O 净化规范

## 适用场景

当任务属于以下场景时优先使用本 skill：

- 检查 IPA 包内的 dylib 注入情况与 Mach-O `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` 依赖
- **Phong Roblox iOS 专项净化**：剥离二次分发打包者注入的 `deltax.dylib` / `BabyRoblox` getkey 验证层与广告，保留 Delta 核心 `libgloop.dylib`
- 剥离二次打包者恶意/额外注入的 dylib（例如 getkey 锁、广告模块、MobileSubstrate tweak）
- 保留官方原始 framework 与指定的合法注入层（如 Delta executor `libgloop.dylib`、Swift runtime）
- 自动修补 Mach-O 头部（平移后续 load commands 消除空洞、递减 `ncmds`、更新 `sizeofcmds`）防止 App 启动 crash
- 支持直接输入 appinstall / direct URL 一键下载、解包、清理并重打包为干净的 `.ipa` 文件

## 工具链与依赖

- **PowerShell (pwsh / powershell 5.1+)**
- **.NET System.IO.Compression.FileSystem** (内置，无需额外工具)
- **可选：optool / ldid / codesign** (如需在 macOS/Linux 上进一步重签名)

## 核心脚本

### `scripts/strip-ipa-dylib.ps1`

#### 参数说明
- `-InputIpa <String>`: 目标 `.ipa` 文件路径（若指定 `-Url` 则可省略）
- `-Url <String>`: 支持传入 `appinstall.cloud/install/...` 页面或直链 `.ipa`，脚本将自动解析并下载
- `-OutputIpa <String>`: 输出净化后的 `.ipa` 路径（可选，默认 `[原名]_stripped.ipa` 或 `[原名]_delta_clean.ipa`）
- `-Preset <String>`: 专项预设方案：
  - `"phong-roblox"`: 自动匹配并剥离 `deltax.dylib`、`Baby_roblox`、`BabyRoblox` 等 Phong 注入层，同时白名单保护 `libgloop.dylib` 及 Roblox 官方库
- `-StripDylib <String[]>`: 手动指定要剥离的 dylib 文件名、路径或正则匹配模式（如 `"deltax"`, `"admodule"`）
- `-ListOnly`: 仅扫描并输出 IPA 内部 dylib 列表与 Mach-O load commands，不做任何修改
- `-KeepExtracted`: 保留临时解压目录供人工深度审查

#### 典型用法

```powershell
# 1. Phong Roblox iOS 一键净化（本地 IPA 文件）
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -InputIpa "phongroblox.ipa" -Preset phong-roblox

# 2. Phong Roblox iOS 一键从 URL 下载并净化
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -Url "https://appinstall.cloud/install/ivjudmr50000" -Preset phong-roblox

# 3. 快速检查 IPA 中的 dylib 和 Mach-O 依赖
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -InputIpa "target.ipa" -ListOnly

# 4. 手动剥离指定 dylib 并输出干净的 IPA
powershell -NoProfile -ExecutionPolicy Bypass -File skills/ipa-dylib-strip/scripts/strip-ipa-dylib.ps1 -InputIpa "target.ipa" -OutputIpa "clean.ipa" -StripDylib "admodule"
```

## 案例剖析：Phong Roblox iOS 逆向分析与净化

### 1. 结构与注入机制
二次分发包（如 `phongrobloxchimbe5cm`）通常包含两层注入：
1. **Delta Executor 核心：** `Payload/Roblox.app/libgloop.dylib` (~15.7 MB)
   - Delta 官方的主执行器核心，负责 Lua 脚本环境与 UI 渲染。
2. **Phong 二次注入层：** `Payload/Roblox.app/deltax.dylib` (~358 KB)
   - Mach-O 中以 `LC_LOAD_WEAK_DYLIB @executable_path/deltax.dylib` 挂载。
   - 内部包含 `BabyRobloxDisplay`、`initKeyAuthGUI`、`_keyAuthView`、`_keyTextField`。
   - 启动时强制弹窗阻断游戏，向 `https://phongrobloxios.duckdns.org/api.php?hwid=%@&key=%@` 校验 HWID 与 key。

### 2. 净化目标
- **清除 `deltax.dylib`**：彻底抹除 Phong 的弹窗、HWID 收集与 DuckDNS 强制 getkey 流程。
- **保留 `libgloop.dylib`**：确保 Delta 核心执行器完整保留并正常载入。
- **保护官方 Frameworks**：`RobloxLib.framework`、`Persona2.framework`、`Reaper.framework`、`libswift_Concurrency.dylib` 等不得损坏。

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
1. 定位需要删除的 load command 偏移 `Offset` 与长度 `Size`。
2. **内存平移（Load Command Memory Shifting）**：
   - 将该命令之后的所有 load commands 整体向左平移 `Size` 字节，杜绝中间出现 0x0 空洞导致 iOS dyld 解析异常。
   - 将末尾腾出的空间清零（Zero-fill）。
3. 将 Mach-O Header `0x10` 处的 `ncmds` 递减 1。
4. 将 Mach-O Header `0x14` 处的 `sizeofcmds` 递减 `Size`。
5. 将修补后的主二进制写回。
6. 从 bundle 目录下永久删除目标 `.dylib` 文件。

### Phase 4: 重打包与重签名验证 (Repack & Verify)
1. 用 ZipArchive 将 `Payload/` 等目录重新打包为 `.ipa`。
2. 再次执行 `-ListOnly` 校验：
   - 目标 dylib 文件已不存在于 zip 树中。
   - Mach-O load command 列表中不再出现该条目。
   - 保留的正常 dylib（如 `libgloop.dylib`）完整无损。
3. 提示用户使用 ESign / TrollStore / AltStore 进行安装或重签名。
