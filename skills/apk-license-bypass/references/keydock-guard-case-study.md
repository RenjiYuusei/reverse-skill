# Case Study: DN PROXY 1.0 商业卡密与 KeyDock Guard 双层绕过复盘

## 1. 背景与目标

- **目标样本**：`DN PROXY_1.0.apk`
- **保护类型**：Java 层 `AuthActivity` 远程 Key 校验 + 底层 Native SO (`libkeydockguard.so`) ARM64 双重门禁。
- **用户诉求**：去除强制 GetKey / 卡密验证弹窗，打开应用直接进入 `DashboardActivity`。

---

## 2. 第一阶段：Java / Smali 层绕过与出现的陷阱

### 2.1 初始尝试
通过 Jadx 逆向定位到启动 Activity 为 `com.dripclient.wireforge.security.AuthActivity`。修改 `AuthActivity.smali`，在 `onCreate` 中直接通过 `Intent` 跳转到 `DashboardActivity`：

```smali
new-instance v0, Landroid/content/Intent;
const-class v1, Lcom/dripclient/wireforge/ui/DashboardActivity;
invoke-direct {v0, p0, v1}, Landroid/content/Intent;-><init>(Landroid/content/Context;Ljava/lang/Class;)V
invoke-virtual {p0, v0}, Lcom/dripclient/wireforge/security/AuthActivity;->startActivity(Landroid/content/Intent;)V
invoke-virtual {p0}, Lcom/dripclient/wireforge/security/AuthActivity;->finish()V
return-void
```

### 2.2 触发的陷阱（Crash & Freeze）
- **现象 1：直接 Crash（闪退）**：由于直接删除了 `AuthActivity` 中的原有方法，但匿名内部类（如 `ExecutorService` 任务）编译后仍保留了对 `AuthActivity.a(I)I` 的虚方法调用，导致 Dalvik/ART 加载字节码时报 `NoSuchMethodError`。
  - *解决方案*：必须保留空桩（Stub）方法：
    ```smali
    .method public final a(I)I
        .locals 1
        const/4 v0, 0x0
        return v0
    .end method
    ```
- **现象 2：卡 Logo / 假死后闪退**：当 Smali 修复后进入应用，Splash/Dashboard 依然卡在 Logo 页面并最终闪退。
  - *原因排查*：`DashboardActivity` 或全局 Application 在后台异步调用了 Native SO 库：
    ```java
    Gate.active();
    Gate.init(context);
    Gate.login(key);
    ```
  - 当没有进行正确的 KeyDock 初始化和验证时，SO 内部的 watchdog 线程或 native check 检测到未授权状态，触发主动 `exit` 或抛出未捕获异常。

---

## 3. 第二阶段：Native SO 动态 JNI 注册与 ARM64 Patch

### 3.1 剥离符号下的函数定位
`libkeydockguard.so` 的 `.symtab` 已经被 strip，且没有显式的 `Java_com_...` 导出符号。说明该库在 `JNI_OnLoad` 中通过 `RegisterNatives` 进行了动态方法绑定。

### 3.2 解析 `.rela.dyn` 结构
动态绑定的 `JNINativeMethod` 结构体：
```c
typedef struct {
    const char* name;
    const char* signature;
    void*       fnPtr;
} JNINativeMethod;
```
通过解析 `.rela.dyn` 中的 `R_AARCH64_RELATIVE` 重定位项（每个 24 字节）：
- `Offset 0xBFF0` → 指向 `"active"`
- `Offset 0xBFF8` → 指向 `"()Z"`
- `Offset 0xC000` → 指向函数实现 `0x21D8`
- `Offset 0x1017` → 指向 `"init"` / `0x1C8C`
- `Offset 0x1DE0` → 指向 `"login"`

### 3.3 ARM64 Opcode 二进制 Patch
使用 PowerShell 直接将对应文件偏移改写为汇编常数返回：

1. **`Gate.active()` (Offset `0x21D8`)**:
   - 原汇编指令替换为：`MOV W0, #1; RET`
   - Hex: `20 00 80 52 C0 03 5F D6`
2. **`Gate.init()` (Offset `0x1C8C`)**:
   - 原汇编指令替换为：`MOV W0, #1; RET`
   - Hex: `20 00 80 52 C0 03 5F D6`
3. **`Gate.login()` (Offset `0x1DE0`)**:
   - 返回 `null`（或空字符串），避免 Java 层尝试解析无效 native string 指针：
   - 替换为：`MOV X0, #0; RET`
   - Hex: `00 00 80 D2 C0 03 5F D6`

---

## 4. 第三阶段：重打包与验证

1. 重新打包：
   ```powershell
   apktool b DN_PROXY_1.0\apktool -o DN_PROXY_bypass.apk --no-crunch
   ```
2. 签名：
   ```powershell
   jarsigner -sigalg SHA256withRSA -digestalg SHA-256 -keystore debug.keystore -storepass android DN_PROXY_bypass.apk androiddebugkey
   ```
3. 效果：
   - 应用启动无任何 GetKey 弹窗，直达 Dashboard 主界面。
   - 移除所有网络卡密心跳，Native SO 鉴权全程返回 `true`，运行平稳无闪退。
