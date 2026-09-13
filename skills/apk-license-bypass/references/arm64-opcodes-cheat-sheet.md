# ARM64 (AArch64) Binary Patching Opcodes Cheat Sheet

本速查表整理了在 Android ELF `.so` 逆向工程中，针对 ARM64 (AArch64, Little-Endian) 架构进行静态机器码替换的最常用指令组合。

## 1. 常用函数返回值 Patch 模式

在 AArch64 ABI 中：
- 32 位整数 / 布尔值返回值存放在寄存器 `W0`
- 64 位整数 / 指针 / 对象引用（如 JNI 的 `jobject`, `jstring`, `jclass`）存放在寄存器 `X0`
- 函数返回指令为 `RET`（即 `RET X30`）

| 意图 (Semantic) | 汇编指令 (Assembly) | Little-Endian Hex 机器码 | 说明 |
|-----------------|---------------------|--------------------------|------|
| **返回 `true` / `1`** | `MOV W0, #1`<br>`RET` | `20 00 80 52 C0 03 5F D6` | 常用于 `isAuth()`, `checkLicense()`, `init()`, `active()` 等布尔或整型校验 |
| **返回 `false` / `0`** | `MOV W0, #0`<br>`RET` | `00 00 80 52 C0 03 5F D6` | 常用于 `isRooted()`, `isEmulator()`, `isDebuggerAttached()` |
| **返回 `null` / `0` (指针)** | `MOV X0, #0`<br>`RET` | `00 00 80 D2 C0 03 5F D6` | 常用于返回 `jstring` 或对象指针的函数，防止访问非法指针引发 SIGSEGV |
| **返回 `-1`** | `MOVN W0, #0`<br>`RET` | `00 00 80 12 C0 03 5F D6` | 常用于返回错误码或忽略特定操作 |
| **空操作 (NOP)** | `NOP` | `1F 20 03 D5` | 用于抹除特定函数调用（如 `exit(0)`, `kill()`, `abort()`） |
| **无条件直接返回 (Void)** | `RET` | `C0 03 5F D6` | 用于 `void` 返回类型的函数，直接退出执行 |

---

## 2. 条件跳转与分支 Patch

当需要绕过特定的 `if-else` 分支判断时：

| 汇编指令 | Little-Endian Hex | 说明 |
|---------|-------------------|------|
| `B <offset>` | 计算目标偏移 | 无条件跳转（绕过中间的失败分支） |
| `NOP` | `1F 20 03 D5` | 将 `CBZ`, `CBNZ`, `B.EQ`, `B.NE` 替换为 NOP，使代码直接流向下一个块 |

---

## 3. PowerShell 二进制 Patch 示例

```powershell
$soPath = "path/to/target.so"
$bytes = [System.IO.File]::ReadAllBytes($soPath)

# 写入 MOV W0, #1; RET 到 0x21D8
$patch = [byte[]](0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6)
for ($i = 0; $i -lt $patch.Length; $i++) {
    $bytes[0x21D8 + $i] = $patch[$i]
}

[System.IO.File]::WriteAllBytes($soPath, $bytes)
```
