# 技术笔记

移植细节、缺陷根因与验证数据。README 面向使用者，这份文档面向要改代码或提 PR 的人。

## 目录

1. [上游调研结论](#1-上游调研结论)
2. [引擎重编译与中文化](#2-引擎重编译与中文化)
3. [鸿蒙适配细节](#3-鸿蒙适配细节)
4. [验证数据](#4-验证数据)
5. [提交前自查](#5-提交前自查)

---

## 1. 上游调研结论

### 1.1 项目概况

| 项 | 结论 |
|---|---|
| 仓库 | `storytold/vectorcraft`（ArtCraft 团队的 Crafting Apps 之一；另有 `Proddy-0/vectorcraft` 镜像） |
| 定位 | 纯 Rust 编写的 Adobe Illustrator 工作流平替（矢量插画编辑器） |
| 架构 | cargo workspace：27 个 `crates/*` + `apps/vectorcraft`（桌面）+ `apps/vectorcraft-cli` + `apps/vectorcraft-web` |
| Web 端 | `eframe`（egui）+ `wgpu`（WebGPU 优先、WebGL2 回落），与 PhotoCraft 同架构 |
| 构建 | `cd apps/vectorcraft-web && trunk build --release`；依赖 craft-libs（git）+ crates.io |
| 版本 | v0.12.0（2026-10-16 发布）；上游自评约为 Illustrator 功能面的 69–75% |
| 许可 | MIT / Apache-2.0 双许可 |

### 1.2 发布包里有什么

`vectorcraft-web-0.12.0.zip`（21.5 MB）内含：

| 文件 | 大小 | 说明 |
|---|---|---|
| `vectorcraft-web-<hash>_bg.wasm` | 61.7 MB | 引擎本体 |
| `vectorcraft-web-<hash>.js` | 161 KB | wasm-bindgen ESM 胶水层 |
| `index.html` | 2 KB | `<script type="module">` + `await init({module_or_path: ...})` |

**结论：不能直接用发布包**，三个原因（见下）。

### 1.3 为什么必须从源码重编译

| 问题 | 证据 | 后果 |
|---|---|---|
| UI 字体不含 CJK 字形 | `crates/ui-egui/src/theme.rs::install_fonts()` 只内嵌 Inter / Source Sans 3 / JetBrains Mono；craft-fonts 未参与发布构建（zip 内无 `fonts/` 目录） | 界面切简体中文后汉字全是豆腐块 |
| ESM 胶水层无法在鸿蒙加载 | 上游 index.html 用 `<script type="module">` + `import` | ArkWeb 的 ES Module 加载器不支持 `resource://` 协议 |
| 宿主无法下发配置 | `?webgl` / `?lang=` 读自 `location.search` | `resource://rawfile` 页面不能改写自己的查询串，外壳的「渲染后端」按钮无法生效 |

> 附带确认：上游**自带完整 i18n 框架**（`crates/ui-egui/src/i18n/*.tsv`，含 `zh-hans.tsv` / `zh-hant.tsv`），
> 语言代码 `zh-hans` 经 `set_system_locales` 动态匹配，无需改默认值逻辑。

---

## 2. 引擎重编译与中文化

### 2.1 环境（Windows，无 MSVC）

| 项 | 选型 | 原因 |
|---|---|---|
| host 工具链 | `x86_64-pc-windows-gnu`（rustup 自带 MinGW） | 本机无 Visual Studio / link.exe；gnu 工具链自包含 |
| 镜像 | crates.io → rsproxy sparse；github.com → gh-proxy.com（git url 改写） | 国内直连 github 只有几 KB/s |
| trunk | v0.21.1 预编译二进制 | 免去 `cargo install` 的编译 |
| Rust | stable 1.99.1（≥ 上游要求的 1.95） | edition 2024 |

> ⚠️ **构建目录必须全 ASCII**：第一版在 `C:\Users\hzm\WorkBuddy\鸿蒙开发区\` 下构建，
> MinGW 的 `ld` 在编译 `serde_derive`（proc-macro，host 目标）时报
> `ld: cannot find ...rcgu.o`。移到 `D:\vc-build\` 后正常。

### 2.2 相对上游的改动（4 处）

补丁：`tools/build_engine_zh/engine-zh.patch`。

| # | 文件 | 改动 | 原因 |
|---|---|---|---|
| 1 | `assets/fonts/NotoSansSC-Subset.ttf` | 新增，839 KB / 3369 字形 | Noto Sans SC VF 在 wght=400 实例化后子集化：覆盖全部 i18n 词条表 + ASCII + 拉丁扩展 + 标点/箭头/数学符号 + CJK 标点全角；字体名改为 `VectorCraft Sans SC`（OFL 保留字体名合规） |
| 2 | `crates/ui-egui/src/theme.rs` | `install_fonts()` 注册 `NotoSansSC`，并把它 push 到所有字族回退链末尾 | 界面（菜单/面板/提示）中文渲染；英文仍走 Inter / Source Sans 3 |
| 3 | `crates/text/src/fontdb.rs` | `BUNDLED` 数组加入子集字体 | 文档文本（文字工具）的中文回退 |
| 4 | `apps/vectorcraft-web/src/web.rs` | 新增 `js_flag()`；`web_options()` 增加 `__VC_WEBGL` 判断，`detect_language()` 增加 `__VC_LANG` | 宿主经桥接下发渲染后端与界面语言；`?webgl` / `?lang=` 查询参数行为保留 |

### 2.3 字体子集

```
[1/3] character set: 4412 unique chars
[2/3] instantiating VF at wght=400 ...
[3/3] subsetting ...
done: 838,988 bytes (819 KiB), 3369 glyphs, 1468 Han chars
```

子集化脚本 `gen_cjk_subset.py` 扫描 `crates/ui-egui/src/i18n/*.tsv` 的全部词条
（25 种语言，含 zh-hans 2067 行、zh-hant、ja、ko…），因此新增语言会自动扩大子集。

### 2.4 trunk 的 post_build 钩子

上游 `Trunk.toml` 的 `[[hooks]] post_build cargo xtask web-fonts` 会把 craft-fonts 的
Web 字体拷进站点。我们没有 `CRAFT_FONTS_DIR`（`WEB_FONTS` 为空，钩子本是空操作），
且该钩子触发 host 侧 xtask 的 **debug** 编译，在 rustup 自带 MinGW 上失败：

```
x86_64-w64-mingw32-gcc: fatal error: '-fuse-linker-plugin', but liblto_plugin.dll not found
```

rustup 的 `x86_64-pc-windows-gnu` 工具链**不附带** `liblto_plugin.dll`（`self-contained/`
里只有 crt2.o 与导入库），而 release 侧的 host 链接（proc-macro dylib）不触发该路径，
所以主构建不受影响、只有钩子受影响。**处理：注释掉该钩子**（见补丁第 4 处之外的
Trunk.toml 改动），需要 craft-fonts 时改回并安装完整 MinGW 工具链。

---

## 3. 鸿蒙适配细节

### 3.1 胶水层：为什么不用 ES Module

上游 `index.html` 用 `<script type="module">` + `import` 加载胶水层，但 **ArkWeb 的 ES Module
加载器不支持 `resource://` 协议**。规避办法是把胶水层从 ESM **等价转换**成经典脚本
（`tools/pack_web.py`，规则与 PhotoCraft 的 `gen_classic_glue.py` 相同），再由页面用
`document.createElement('script') + textContent` 内联注入。转换只有三处：

| 原（ESM） | 现（经典脚本） |
|---|---|
| `export { initSync, __wbg_init as default };` | `window.__VectorCraftModule = { initSync: initSync, default: __wbg_init };` |
| `new URL('..._bg.wasm', import.meta.url)` | `new URL('..._bg.wasm', document.baseURI \|\| 'resource://rawfile/vectorcraft/')` |
| 顶层模块作用域 / 隐式严格模式 | 外层包一层 `(function () { 'use strict'; ... })()` |

转换后 `node --check` 自检语法。

### 3.2 资源读取三层容错

`resource://rawfile` 下不同设备/版本对 `fetch`、`XHR` 的支持存在差异，页面按三层依次尝试：

1. `fetch()` 流式读取（可显示精确进度）；
2. `XMLHttpRequest`（`responseType: 'arraybuffer'`）；
3. **原生分块通道** —— `vcBridge.assetSize()` / `vcBridge.assetChunk()`，
   由 ArkTS 用 `resourceManager.getRawFileContentSync()` 读 rawfile，按 1 MiB base64 回传。

任一层成功即可启动引擎；三层全失败时显示错误详情（同时上报原生侧）。
wasm 读完后以字节形式交给胶水层（`init({ module_or_path: bytes })`），
**不让胶水层自己去 fetch `resource://` 下的 wasm**。

引擎约 65 MB（wasm-bindgen 处理后），首启编译需要十几秒到几十秒，
原生遮罩兜底 5 秒后放行（`Index.ets` 的 `setTimeout`）。

### 3.3 宿主配置：window 全局变量

引擎的 `?webgl` / `?lang=` 依赖 `location.search`。在 `resource://rawfile` 页面里：

- `history.replaceState` 对非 http(s) 方案可能抛 `SecurityError`；
- `location.search` 在规范里是 **unforgeable** 自有属性（不在原型链上），
  `Object.defineProperty` 无法影子它。

因此走源码补丁（第 2.2 节第 4 处）：页面在 `init()` 前把宿主配置写成
`window.__VC_WEBGL` / `window.__VC_LANG`，引擎启动时读取。桥接契约：

| 桥方法（vcBridge） | 页面用途 |
|---|---|
| `renderMode()` → `auto` / `webgl` | `webgl` 时置 `window.__VC_WEBGL = '1'`（引擎 `backends = GL`） |
| `lang()` → `zh-hans` | 置 `window.__VC_LANG`（引擎 `set_system_locales` 的首选标签） |
| `deviceType()` / `viewportWidth()` | 预留（页面自身用 CSS 自适应，暂未消费） |

### 3.4 保存 / 导出与外链

引擎的保存/导出（`apps/vectorcraft-web/src/web.rs::download`）与外链（egui `open_url` →
`window.open`）都依赖浏览器能力，ArkWeb 两者都不处理。全部在外壳层解决，**未改动引擎**：

| 现象 | 根因 | 修法 |
|---|---|---|
| 保存/导出点了没反应 | 引擎造 `<a download>` + `click()`；ArkWeb 不处理 `<a download>` | `index.html` 覆写 `URL.createObjectURL` 记住 blob 映射、覆写 `HTMLAnchorElement.prototype.click` 拦截下载，字节按 256 KiB base64 分块经 `beginSave/saveChunk/finishSave` 交原生，`DocumentViewPicker.save()` 落盘（不可用时兜底 `filesDir/exports`） |
| 外链把编辑器顶掉 | `window.open` 在 Web 组件内变成当前页导航 | 覆写 `window.open` + document 捕获阶段 click 监听，http(s) 链接一律交 `vcBridge.openUrl` 拉系统浏览器 |

打印（`File → Print`）用隐藏 iframe + `contentWindow().print()` 实现，ArkWeb 内不可用；
需打印时先导出 PDF（导出链路本身是通的）。

---

## 4. 验证数据

| 项 | 方法 | 结果 |
|---|---|---|
| 构建 | `trunk build --release`（D:\vc-build，ASCII 路径） | 成功；release wasm 85 MB → wasm-bindgen 后 65 MB |
| 经典脚本语法 | `node --check *.classic.js` | OK |
| 中文字体嵌入 | wasm 内检索改名后的字体名 + sfnt 头 | `VectorCraft Sans SC` ×4；有效 sfnt 头 27 个（含 6 个内嵌字体） |
| 中文词条 | wasm 内检索 zh-hans 词条 | `zh-hans` ×4；「钢笔」×3、「画板」×79 |
| ESM→经典脚本等价性 | 仅改写 export / import.meta.url / 作用域三处，其余逐字节相同 | 由 pack_web.py 的正则保证，改写后 node --check 通过 |

未做（需真机）：ArkWeb 内实际启动、WebGL2/WebGPU 后端切换、保存选择器落盘、
平板/PC 三形态自适应。这些需要在 DevEco + 真机/模拟器上验证，日志搜 `[VectorCraft]`。

---

## 5. 提交前自查

`build-profile.json5` 一旦在 DevEco 里勾过「自动签名」，就会被写回**本机用户目录下的
绝对路径**与加密口令 —— 这样的版本**不要提交**。仓库里附了 `tools/check-before-publish.py`：

```bash
python tools/check-before-publish.py      # 命中任一项即以退出码 1 结束
```

它扫的是：签名配置目录 `signingConfigs`、`storePassword` / `keyPassword` / `keyAlias`、
证书文件后缀（`.p7b` / `.p12` / `certpath`），以及 Windows / macOS / Linux 的**本机绝对路径**。

---

## 6. 构建链路验证（DevEco Studio 6.1.1 / hvigor 6.24.4）

2026-10-17 用本机工具链做了一次完整的命令行构建，暴露并修复了两个问题。

### 6.1 hvigor 与 ohpm 的 modelVersion 必须一致

**现象**：DevEco 打开工程报
「hvigor 配置的 modelVersion（未配置）与 ohpm 配置的 modelVersion(6.1.0) 不一致，
范围是 5.0.0 到 6.1.1」。

**根因**：根 `oh-package.json5` 写了 `"modelVersion": "6.1.0"`，但工程里**没有
`hvigor/hvigor-config.json5`**（交付时漏了该文件），hvigor 侧读不到 modelVersion。

**修复**：补 `hvigor/hvigor-config.json5`，`modelVersion` 与 `oh-package.json5` 保持同值：

```json5
{
  "modelVersion": "6.1.0",
  "dependencies": {},
  "execution": {},
  "logging": {},
  "debugging": {},
  "nodeOptions": {}
}
```

**验证**：`hvigorw --sync --no-daemon` 通过，不再报版本不一致。
注意两者是**联动**的：换 IDE 版本时（如 6.1.1 → modelVersion 可写 `6.1.1`），
`hvigor/hvigor-config.json5` 与 `oh-package.json5` 必须一起改。

### 6.2 Column.alignItems 的参数类型

**现象**：`CompileArkTS` 报 5 处
`Argument of type 'Alignment' is not assignable to parameter of type 'HorizontalAlign'`。

**根因**：`Alignment` 只能用于 `Stack.alignContent()` 和通用 `.align()`；
`Column.alignItems()` 的交叉轴是水平方向，类型是 `HorizontalAlign`（`Row` 则是 `VerticalAlign`）。

**修复**：`Index.ets` 中 5 处 `.alignItems(Alignment.Center)` →
`.alignItems(HorizontalAlign.Center)`（ModeOverlay / AboutOverlay 的遮罩与面板）。

### 6.3 构建结果

```bash
export DEVECO_SDK_HOME="D://DevEco Studio//sdk"
"D://DevEco Studio//tools//node//node.exe" \
  "D://DevEco Studio//tools//hvigor//bin//hvigorw.js" \
  assembleHap --mode module -p product=default -p module=entry@default \
              -p buildMode=debug --no-daemon
```

`BUILD SUCCESSFUL in 25 s`，产出 `entry/build/default/outputs/default/entry-default-unsigned.hap`
（68.8 MB，含 65 MB 引擎 wasm）。未配置签名时 `SignHap` 只给 WARN，属预期。
本机 SDK 为 API 24（HarmonyOS 6.1.1），工程声明 `targetSdkVersion 6.1.0(23)` 可正常编译。

---

## 7. 最近文件（原生实现）

### 7.1 为什么不用引擎自带的

上游的「最近文件 / 打开最近使用的文件 1–15」记录的是**文件路径**
（`ui-egui` 的 `io::note_recent(path)`，菜单项 `Open Recent File N`）。
Web/ArkWeb 里文件没有可复用的真实路径（用 `<input type=file>` 选到的
文件只是一个 `File` 对象），所以这份列表在网页内核下必然点不开 —— 用户看到的现象就是
「列表里什么都没有/点了没反应，杀了进程更没」。

### 7.2 设计

| 环节 | 做法 |
|---|---|
| 记录 | `ResourceBridge` 保存成功后回调节点到 `RecentStore.add()`：写一份副本到 `filesDir/recents/<时间戳>-<文件名>`，条目（名称/原路径/副本路径/大小/时间）序列化进 Preferences |
| 持久化 | `@kit.ArkData` 的 Preferences（文件 `vc_recent_files`），杀进程、重启都在；上限 12 条，同名覆盖，淘汰时删副本 |
| 打开 | 读副本字节 → 分块（256 KB base64）推给页面 → 页面还原成 `File`，用 `DataTransfer` 合成一次 `drop`，派发到画布 |
| UI | 原生「最近文件」面板（侧栏 / 顶栏 / 底栏第二个入口），显示名称、时间、大小，支持单条移除与清空 |

### 7.3 为什么合成 drop 可行

读了 eframe 0.36.2 的 web 端实现（`src/web/events.rs: install_drag_and_drop`）：
监听器只做三件事 —— 取 `event.data_transfer().files()`、把每个 `File` 包成
`dropped_file::WebFile`、塞进 `input.raw.dropped_files`；**没有校验 `isTrusted`**，
也不检查事件来源。因此脚本构造的 `DragEvent('drop', { dataTransfer })` 与真实拖放等价。

引擎侧收到后走 `drop_target()`：`.vectorcraft` / `.drawcraft` 以及插件、脚本、
库等类型直接 `DropTarget::Open`，其余图形按落点放置。所以打开工程文件不依赖落点坐标。

对应页面侧代码在 `rawfile/vectorcraft/index.html` 的
`window.__vcOpenFileBegin / __vcOpenFileChunk / __vcOpenFileEnd`。

### 7.4 真机验证（MatePad，3120×2080）

1. 新建信纸文档 → Ctrl+S → 「存储为」→ 确定 → 系统保存选择器 → 保存
2. 状态栏出现「已保存: Untitled-2.vectorcraft」，最近文件面板立即多出
   `Untitled-2.vectorcraft 今天 19:59 · 21 KB`
3. 点条目：hilog 依次出现
   `已把最近文件注入页面: ... 21515 字节` →
   `宿主打开最近文件：...（21515 字节）` →
   `已交给引擎打开：...` →
   引擎日志 `Title("*Untitled-2.vectorcraft — VectorCraft")`，标签页变为
   `*Untitled-2.vectorcraft @ 46.46%`
4. `aa force-stop` 后重新启动，面板里条目仍在；冷启动直接点开也正常载入

### 7.5 已知取舍

- 副本会额外占用空间（与工程文件等大，最多 12 份）；卸载应用一并清除。
- 只在**保存**时登记；通过引擎「打开」对话框打开的外部文件目前不会进列表
  （要接 `onShowFileSelector` 才能捕获，后续可加）。
- 引擎自带的那份路径列表仍然存在且无效，界面上没有屏蔽它 —— 使用说明里已注明改走原生面板。

---

## 8. 外壳交互修正（按压态残留 / 收起态品牌图标）

### 8.1 stateStyles 的 pressed 会卡住不恢复

**现象**：侧边栏按钮点一次之后背景停在 `#2E3238`（panel_bg_hover）的深灰上，
关闭弹层也不还原，必须切后台或重载才恢复。

**根因**：`Row` / `Image` 上只写了

```ts
.stateStyles({
  pressed: { .backgroundColor($r('app.color.panel_bg_hover')) }
})
```

`pressed` 是**按压中**的临时状态，正常靠 `TouchType.Up` 回落到默认态。
但这些按钮的 `onClick` 会立刻打开覆盖层（最近文件 / 渲染后端 / 关于 …），
覆盖层盖上来后组件的 Up 事件被吃掉，回落动作没有机会执行，视觉状态就冻在那里。

**修复**：不用 `stateStyles`，改成手动维护一个 key：

```ts
@State pressedKey: string = '';

// NavItem / IconButton 内
.backgroundColor(this.pressedKey === key ? $r('app.color.panel_bg_hover') : Color.Transparent)
.onTouch((event: TouchEvent) => {
  if (event.type === TouchType.Down) {
    this.pressedKey = key;
  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
    if (this.pressedKey === key) { this.pressedKey = ''; }
  }
})
.onClick(() => {
  if (this.pressedKey === key) { this.pressedKey = ''; }  // Up 被吃掉时兜底
  action();
})
```

关键是 `onClick` 里**先复位再执行动作**：即使 Up 被覆盖层吃掉，
点击这一下也已经把状态清干净了。`TouchType.Cancel` 一并处理，覆盖滑动取消的情况。

**真机验证**（3120×2080 平板，取按钮空白处像素）：

| 阶段 | 像素 | 含义 |
|---|---|---|
| 未操作（基准） | `(37,38,43)` | panel_bg |
| 弹层打开 | `(16,17,19)` | 遮罩压暗，正常 |
| 弹层关闭后 | `(37,38,43)` | **完全恢复，无残留** |

同一轮还验证了「返回编辑器」（触发引擎整体重载）后按钮同样干净。

### 8.2 收起态顶部的品牌图标

**现象**：侧边栏收起时，顶部只剩一个 38vp 的应用图标悬在左上角，
和引擎自己的菜单栏（文件 / 编辑 / 对象 …）同一水平线，看起来像菜单栏左边的按钮，
但点了没反应（它只是装饰），也没有文字说明。

**修复**：品牌区整块只在 `sidebarExpanded` 时渲染，收起态换成 10vp 的 `Blank` 占位：

```ts
if (this.sidebarExpanded) {
  Row() { Image($r('app.media.app_icon')) ... }   // 图标 + 矢量工坊 + 副标题
  Divider()
} else {
  Blank().height(10)
}
```

顺带去掉了中屏顶栏最左侧那个 26vp 的重复图标（同一张图，纯装饰），
顶栏现在直接从「矢量工坊」文字开头。启动遮罩与关于面板里的图标保留 ——
那两处有文字陪着，语义明确。

`uitest dumpLayout` 复核：收起态侧栏只剩 6 个 20vp 功能图标（x 51–95），
再无 38vp 品牌图标节点。

### 8.3 引擎自绘的品牌标（菜单栏最左那枚图案）

**现象**：菜单栏「文件」左边两格处有一枚小图案（上游刻的是龙头，缩放后很像一匹马），
点它没有任何反应。它不是原生组件，放大看是引擎画在 canvas 里的。

**根因**：`crates/ui-egui/src/chrome.rs::app_bar()`：

```rust
if !system {
    let (r, _) = ui.allocate_exact_size(vec2(MARK, MARK), Sense::hover());
    crate::brand::paint_mark(ui, r);
    ui.add_space(6.0);
}
```

`system` 来自 `system_title_bar()`，其定义是
`!custom_titlebar && prefs.system_title_bar && !cfg!(any(target_os = "macos", target_arch = "wasm32"))`
—— **wasm 上恒为 `false`**，所以 Web 端一定会画这枚 18 pt 的品牌标。

**修复**：给条件补上 wasm 判据，桌面端行为不变：

```rust
if !system && !cfg!(target_arch = "wasm32") {
```

关于对话框（`dialogs/about.rs`）里的品牌标保留：那里有文字说明，语义清楚。

**代价与产物**：需要重编译引擎（`trunk build --release`，增量约 **12 分 30 秒**）。
新产物 `vectorcraft-web-ce0fa9a347cb605_bg.wasm`，68,181,788 字节（比上一版少 124 字节）。

**打包注意**：`pack_web.py` 会用 `INDEX_TEMPLATE` 重建 `index.html`，
而「最近文件」那 91 行 JS 当时是直接手改 rawfile 的页面加进去的。
这次先把这段合并回模板，并校验「模板生成结果 == 当前页面」字节一致，
之后重打包才不会把功能覆盖掉。

**验证**：装机后放大截图 —— 菜单栏从房子按钮（Home）直接开始，图案消失；
再点「最近文件」打开 `Untitled-2.vectorcraft`，标签页、画板、属性面板全部正常。
