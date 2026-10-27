# 原生引擎（去 Web 壳套）

从 v0.16.0 起，VectorCraft 鸿蒙版不再用「WebView + wasm」这套壳，而是把引擎编成
原生库 `libvectorcraft_native.so`，用 wgpu(OpenGL ES) 直接画在 XComponent 的
surface 上。ArkTS 只负责外壳与系统能力（文件选择器、外链、输入法）。

```
Rust: apps/vectorcraft-ohos (cdylib)
  ├─ ndk.rs   OH_NativeWindow_CreateNativeWindowFromSurfaceId + hilog
  ├─ lib.rs   napi 导出：start/stop/resize/touch/mouse/wheel/key/ime_*/take_requests…
  └─ run()    渲染线程：wgpu GL surface → egui ctx.run_ui → app.logic/ui → tessellate
ArkTS: entry/src/main/ets/pages/Index.ets
  └─ XComponent(SURFACE) + onTouch/onMouse/onAxisEvent/onKeyEvent
     └─ 定时 take_requests() 处理 pickOpen / pickPlace / saveAs:* / openUrl:*
```

## 构建

```bash
# 需要 DevEco SDK（默认 D:/ohsdk，必须是指向 SDK 的目录联接，路径里不能有空格）
bash tools/build_engine_native/build_ohos.sh <VectorCraft 源码目录> [--hap] [--debug]
```

脚本会：

1. 在源码树 `.cargo/config.toml` 里补 `[target.aarch64-unknown-linux-ohos]`
   （链接器换成 NDK 的 clang，`-lnative_window -lhilog_ndk.z`。**换机器必须改这里**，
   `CC_*` 环境变量只管 C 依赖的编译，管不到 Rust 的链接器）；
2. `cargo build -p vectorcraft-ohos --release --target aarch64-unknown-linux-ohos`；
3. 把产物复制到 `entry/libs/arm64-v8a/libvectorcraft_native.so`。

首次全量编译约 15–25 分钟（wgpu + vello + 字体栈），之后改 ArkTS 或改引擎逻辑的
增量重链仍要几分钟（单文件 30 MB 级 cdylib 的链接开销）。

## 与 Web 版的差异

| | Web 壳套（v0.12.0 及更早） | 原生（现在） |
|---|---|---|
| 引擎产物 | `rawfile/vectorcraft/vectorcraft_bg.wasm`（65 MB） | `entry/libs/arm64-v8a/libvectorcraft_native.so` |
| 打开文件 | 分块 base64 注入页面 + 合成 drop 事件 | `native.open_file(name, ArrayBuffer)` |
| 保存 | JS 拦截 `<a download>` → 分块回传 | 引擎写 `filesDir/exports/<name>` → 请求 `saveAs:<name>` |
| 渲染后端选择 | WebGPU / WebGL2 二选一 | 只有一条路（wgpu GLES），面板已移除 |
| 中文字体 | 子集字体打进 wasm | 子集字体编进 .so，另挂鸿蒙系统字库兜底 |

## 排查

```bash
hdc shell hilog | grep vectorcraft-ohos
```

引擎侧所有诊断都走 hilog（Rust 的 stdout 在 ArkTS 应用里到不了 hilog）。
