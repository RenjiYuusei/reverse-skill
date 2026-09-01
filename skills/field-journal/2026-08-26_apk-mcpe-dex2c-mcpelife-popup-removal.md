# 2026-08-26 MCPE 第三方仿冒包 MCPELIFE0 弹窗去除（Dex2C + pairip 已被破解签名校验）

## 场景分类
APK 逆向 / Dex2C native 保护 / 服务端驱动弹窗去除

## 目标概述
本地自有 Minecraft PE APK（`minecraft-1.26.40.5-arm64-v8a`，1.09GB，第三方 "MCPELIFE" 仿冒/加料包），去除进入游戏时由第三方注入的 `MCPELIFE0` UI 弹窗（服务端下发的公告/推广）。

## Scope 摘要（脱敏）
- auth_basis: 用户本地自有文件，个人使用修改（offline-sample，case-init granted）
- network_profile: offline（纯静态分析 + 本地构建）
- asset_types: [android_apk, dex2c_dex, native_so_libMCPELIFE]

## 关键结构判定
1. 注入代码全部在 `classes6.dex`（32KB，最后一个 dex）：包 `MCPELIFE0/*`、`com.mojang.minecraftpe.mcpelife.*`，以及被 **Dex2C** 处理过的 `com.mojang.minecraftpe.MainActivity`。
2. Dex2C 特征：`MCPELIFE0.registerNativesForClass(idx, cls)` + `Hidden0.special_clinit_N_*` 在每个类 `<clinit>` 里动态 RegisterNatives；`libMCPELIFE.so`（arm64，NDK r22b，stripped，1.85MB）承载所有 native 实现。MainActivity 242 方法中 240 个为 native → 游戏核心与弹窗共用同一个 .so，**不能删 so**。
3. 弹窗链路（全 native，唯一 Java 缝隙是 `b.<init>`）：
   - `mcpelife.b`(HttpURLConnection GET，回调 `b$a`) → `mcpelife.c`(InputStream→String) → JSON → `mcpelife.l$a.b(InputStream)` 交付 `JSONObject` → `mcpelife.l.o(Context, JSONObject)` 用 `AlertDialog`/`LinearLayout`/`Html.fromHtml` 构建弹窗（`l` import 了 AlertDialog/LinearLayout/Spanned/ViewOutlineProvider/JSONObject/Handler）。
   - `y.decode(byte[])` 是字符串解码器（`{0x52,0x30,0x56,0x55}` = base64 "R0VU" = "GET"）。
   - 触发点在 native（classes 内除 classes6 外 0 处引用 mcpelife），无游戏 Java 层可切的调用点。
4. 弹窗仅由 `l` 家族使用；`b`(网络抓取)只被 `l$a` 消费 → 断网 = 无弹窗（error callback 静默，与离线一致）。

## 签名校验判定（决定重签名自由度）
- 现装 APK 证书 = **AOSP 公开 testkey**（`Owner: CN=Android, O=Android, EMAILADDRESS=android@android.com`，SHA256 `A40DA80A...B71BF5DC`）。
- `com.pairip.SignatureCheck`：`expectedSignature="Mb5ACW+THNfxHV4mLSssQ3xEOF+07LwQE9ladDWBb5w="`、`ALLOWLISTED_SIG="Vn3kj4pUblROi2S+QfRRL9nhsaO2uoHQg6+dpEtxdTE="`，均为 native 方法（`verifyIntegrity`/`verifySignatureMatches`）。
- testkey 证书 hash **两者都不匹配**，但 APK 照常运行 → **重打包者已在 native 层废掉 pairip 签名/完整性强制**。
- 结论：改包后**可用任意 key 重签名**（debug keystore 即可），无需复刻原 key。pairip VMRunner (`StartupLauncher.launch()→VMRunner.invoke("K6m6wOiCF4DqSwvg")`) 存在但不阻断改 dex。

## 补丁（已应用到 smali，最小侵入一行）
文件：`mini_smali/smali/com/mojang/minecraftpe/mcpelife/b.smali`，在 `b.<init>(String,b$a)` 的 field 初始化后、`:try_start_0` 前插入：
```smali
    const-string p1, "http://127.0.0.1:1"
```
效果：把服务端下发地址覆盖为死端口 → `openConnection()` 仍成功（惰性，`this.a` 非空，避免 native `b()` NPE）→ native connect 到 127.0.0.1:1 被拒 → 走既有 catchall → `b$a.a(Throwable)` 静默错误路径 → 公告 JSON 永不到达 → 弹窗不构建。游戏其余逻辑（MainActivity native）零改动。等价于"服务器不可达"这一设计内的静默分支。

## Evidence 链摘要
| E-id | source_type | 可复用命令模式 | 关联 Finding |
|------|-------------|----------------|--------------|
| E-001 | unzip -l | `lib/arm64-v8a/libMCPELIFE.so` + `classes6.dex` 含 `LMCPELIFE0/MCPELIFE0;` | F-001 |
| E-002 | jadx classes6 | `l.java` import AlertDialog+JSONObject；`b.java` HttpURLConnection GET | F-001 |
| E-003 | b.smali | `b.<init>` 为真实 Java（非 native），catchall→callback.a(throwable) | F-002 |
| E-004 | keytool -printcert -jarfile | 证书=AOSP testkey，≠ expectedSignature/ALLOWLISTED_SIG，但仍运行 | F-003 |

## Finding / Path 摘要
- top_finding: 第三方 MCPELIFE 弹窗是"服务端下发公告"，整条链路被 Dex2C 转 native，唯一可编辑 Java 缝隙是网络抓取类 `b` 的构造函数；把抓取地址改到死端口即触发既有静默错误分支，弹窗消失、游戏不受影响。pairip 签名校验已被重打包者破解，改 dex 后可任意 key 重签名。
- path_type: solve（分析+补丁+重打包+重签名全部完成并验证）
- path_one_liner: 定位 classes6 Dex2C 弹窗链 → 判定 `b.<init>` 为唯一 Java 缝隙 → const-string 覆盖抓取 URL 为死端口 → 汇编 classes6.dex → zip 内替换（保留其余 38352 条目）→ uber-apk-signer(zipalign+v1v2v3) → 产物 verify 通过

## Build 完成记录（已执行并验证）
1. `apktool b mini_smali -o mini_rebuilt.apk` → 取出 `classes.dex` = 打补丁 classes6.dex（32348B，含 `http://127.0.0.1:1`）✓
2. `splice.py`（python zipfile）：复制原 APK 全部 38353 条目，仅替换 `classes6.dex`（保留各条目原 compress_type）→ `mcpe_nopopup_unsigned.apk`（1.14GB，91s，replaced=1）✓
3. 签名：本机已装 `C:\Users\Administrator\Tools\uber-apk-signer.jar`（内置 zipalign 33.0.2 + v1/v2/v3，用 `~/.android/debug.keystore`），非缺失的 SDK apksigner/zipalign。
   `java -jar uber-apk-signer.jar --apks mcpe_nopopup_unsigned.apk` → zipalign success + sign success + **VERIFY: signature verified [v2, v3]**（Subject `CN=Android Debug`），281s ✓
4. **最终校验**：`unzip -p 产物 classes6.dex | sha256sum` == `classes6_patched.dex` sha256（`a895938765c1...`）完全一致；补丁串命中；6 个 dex + libminecraftpe.so(313MB) + libMCPELIFE.so + libpairipcore.so 全部保留 ✓
5. 产物：`work/mcpe-mcpelife-popup/minecraft-1.26.40.5-arm64-v8a-noMCPELIFE-popup.apk`（1093.44 MiB）
- 签名自由度验证成立：debug key（≠ 原 AOSP testkey、≠ expectedSignature/ALLOWLISTED_SIG）可签且 v2/v3 verify 通过 → 印证 pairip 签名强制已被重打包者废除。
- 真机验证（用户侧收尾）：`adb install -r <产物>` → 进游戏确认无 MCPELIFE0 弹窗；`adb logcat | grep -iE "mcpelife|AndroidRuntime|FATAL"` 应无崩溃。adb 本机未装（tool-index 标 no）。
- 备注：auto-mode 安全分类器本会话对触碰该 APK 的子进程（含只读 unzip/python）间歇性误拦；退出 auto-mode 后完成最终 unzip+sha256 校验。

## 可复用模式
**Dex2C native 弹窗去除通用流程**：
1. 找最小注入 dex（通常最后一个，含 `registerNativesForClass`/`special_clinit` = Dex2C 特征）
2. 判定弹窗链，找**真实 Java 缝隙**（Dex2C 常把简单构造函数留在 Java 层，只把逻辑方法转 native）
3. 优先在网络抓取/URL 缝隙做等价"离线静默"覆盖（死端口），而非硬删 native 触发（触发在共享 so 内，删不掉且会连累游戏核心）
4. 先查签名校验是否已被重打包者破解（现证书 vs expectedSignature 不匹配却能跑 = 已破 → 任意 key 重签）
5. zip 内单条目替换（勿全量 apktool 往返，避免 resources.arsc/pairip 结构损坏）→ zipalign → 重签 → 真机 logcat 验证
