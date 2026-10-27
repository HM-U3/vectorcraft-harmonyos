# 引擎重编译配方（VectorCraft → HarmonyOS 中文化）

把上游 VectorCraft 的 Web 版从源码重新编译，内嵌中文字体、默认简体中文界面，
并加入鸿蒙宿主所需的两个配置注入点。产物即 `entry/src/main/resources/rawfile/vectorcraft/`。

## 1. 为什么不能直接用发布包

上游 Releases 提供了预编译的 `vectorcraft-web-0.12.0.zip`（`index.html` + ESM 胶水层 + 61.7 MB wasm），
但该构建：

1. **UI 字体不含 CJK 字形** —— `install_fonts()` 只内嵌 Inter / Source Sans 3 / JetBrains Mono；
   wasm32 下读不到系统字体（`craft-fonts` 也未参与该构建）。界面切到简体中文后，
   所有汉字会渲染成空白/豆腐块。
2. **ESM 胶水层无法在鸿蒙里加载** —— ArkWeb 的 ES Module 加载器不支持 `resource://` 协议。
3. **宿主无法下发配置** —— `?webgl` / `?lang=` 依赖 `location.search`，
   而 `resource://rawfile` 页面不能改写自己的查询串，鸿蒙外壳的「渲染后端」选项无法生效。

因此从源码重编译，改动全部集中在本目录的补丁里（见第 4 节）。

## 2. 需要什么

| 项 | 版本 / 说明 |
|---|---|
| Rust stable | ≥ 1.95（上游 `rust-version = "1.95"`，edition 2024）。实测 1.99.1 |
| 目标 | `wasm32-unknown-unknown` |
| trunk | 0.21.x（预编译二进制即可，无需 cargo install） |
| host 工具链 | Windows 上无 MSVC 时用 `x86_64-pc-windows-gnu`（rustup 自带 MinGW，自包含） |
| Python | fontTools + brotli（生成中文字体子集） |
| 网络 | crates.io 走 rsproxy 镜像；github.com 的 git 依赖走代理（见下） |

> ⚠️ **工作区路径不能含非 ASCII 字符**：MinGW 的 `ld` 处理不了中文路径，
> 会在编译 proc-macro（如 `serde_derive`）时报 `ld: cannot find ...rcgu.o`。
> 本配方在 `D:\vc-build\vectorcraft-src` 下构建。

### 2.1 一键环境配置（Windows）

```bash
# rustup（rsproxy 镜像）
curl -LO https://rsproxy.cn/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe
RUSTUP_DIST_SERVER=https://rsproxy.cn RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup \
  ./rustup-init.exe -y --profile minimal --default-toolchain stable-x86_64-pc-windows-gnu
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add wasm32-unknown-unknown

# ~/.cargo/config.toml
#   [source.crates-io]
#   replace-with = 'rsproxy-sparse'
#   [source.rsproxy-sparse]
#   registry = "sparse+https://rsproxy.cn/index/"
#   [net]
#   git-fetch-with-cli = true

# github.com 走代理（craft-libs 等 git 依赖）
git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"

# trunk 预编译二进制
#   https://github.com/trunk-rs/trunk/releases 下载 trunk-x86_64-pc-windows-msvc.zip
```

## 3. 一条命令

```bash
cd apps/vectorcraft-web
trunk build --release        # 产物在 dist/web（Trunk.toml 指定）
```

随后用鸿蒙侧的打包脚本生成 rawfile（见第 5 节）。

## 4. 相对上游源码的改动（全部改动）

补丁文件：`engine-zh.patch`（相对 v0.12.0 的 main 分支，含 7 个文本文件改动；
新增的字体二进制 `assets/fonts/NotoSansSC-Subset.ttf` 不入补丁，由第 4 节的脚本生成）。改动均为最小改动：

| 文件 | 改动 | 原因 |
|---|---|---|
| `assets/fonts/NotoSansSC-Subset.ttf` | 新增，855 KB / 3550 字形 | Noto Sans SC 可变字体在 wght=400 处实例化后子集化：覆盖全部 i18n 词条表（`crates/ui-egui/src/i18n/*.tsv`，含 zh-hans / zh-hant）**＋ 所有 Rust 字符串字面量里的汉字**（写死在源码里的品牌名等，见第 4 节）+ ASCII + 拉丁扩展 + 标点/箭头/数学符号 + CJK 标点与全角字符。字体名已改为 `VectorCraft Sans SC`（脚本内 `rename_family()` 强制执行） |
| `crates/ui-egui/src/theme.rs` | `install_fonts()` 注册 `NotoSansSC` 并追加到所有字族回退链末尾 | 界面（菜单/面板/提示）的中文渲染；英文仍走 Inter / Source Sans 3 |
| `crates/text/src/fontdb.rs` | `BUNDLED` 数组加入子集字体 | 文档文本的中文回退（文字工具输入中文） |
| `apps/vectorcraft-web/src/web.rs` | 新增 `js_flag()`，`web_options()` / `detect_language()` 读取 `window.__VC_WEBGL` / `window.__VC_LANG` | 鸿蒙宿主经桥接下发渲染后端与界面语言；`resource://` 页面无法改写查询串，查询参数（`?webgl` / `?lang=`）保留原行为 |
| `apps/vectorcraft-web/Trunk.toml` | 注释掉 `post_build` 钩子 | 该钩子会触发 host 侧 xtask 的 debug 编译，rustup 自带 MinGW 缺 `liblto_plugin.dll` 会失败；没有 `CRAFT_FONTS_DIR` 时它本是空操作 |
| `crates/ui-egui/src/chrome.rs` | `app_bar()` 里品牌标的绘制条件加 `&& !cfg!(target_arch = "wasm32")`；应用栏不再显示 Discord 按钮 | Web/ArkWeb 端不画引擎自带的品牌标：18 pt 的图标孤悬在最左、与「文件/编辑/…」同一行，看着像按钮却点不动；品牌由原生外壳（侧栏展开态）呈现。桌面端行为不变，关于对话框仍显示 |
| `crates/ui-egui/src/canvas.rs` | `home()` 首屏标题改为「矢量工坊」，并移除「社区」区块 | 应用名与首屏标题不一致，审核会判「名称与内容不符」；社区区块里的 Discord 在境内不可访问（属无效功能），另三个外链属站外导流 |
| `crates/ui-egui/src/dialogs/about.rs` | 移除「关于」窗口中的社区与外链区块 | 同上；版本、许可证与致谢保留，署名上游属于许可要求 |

子集化脚本：`gen_cjk_subset.py`（从 PhotoCraft 移植，扫描路径改为本仓库）：

```bash
python gen_cjk_subset.py --src <vectorcraft 源码根> --vf NotoSansSC-VF.ttf --out assets/fonts/NotoSansSC-Subset.ttf
```

**字符集来源有两处，缺一个就会出豆腐块：**

1. `crates/ui-egui/src/i18n/*.tsv` 全部语种词条；
2. `crates/**/*.rs`、`apps/**/*.rs` 里字符串字面量中的汉字（`collect_rs_literals()`，注释不计入）。

第 2 条是因为首屏品牌「矢量工坊」是直接写死在 `canvas.rs` 里的字面量，不走词条表。
只扫词条表时「坊」不在子集内，界面会把它画成一个空心方框（`口`），
看起来像错别字 —— 这个坑已经踩过一次，脚本现在会兜住。

> 未改动 `.wasm` 之外的任何引擎逻辑；`?webgl` / `?lang=` 查询参数行为与上游完全一致。

## 5. 生成鸿蒙 rawfile

```bash
python tools/pack_web.py            # 读 dist/web，写 entry/src/main/resources/rawfile/vectorcraft/
```

脚本做四件事：

1. 拷贝 wasm 与上游 ESM 胶水层（原样保留备查）；
2. 把 ESM 胶水层**等价转换**为经典脚本（`*.classic.js`）——`export {...}` → `window.__VectorCraftModule`，
   `new URL(..., import.meta.url)` → `new URL(..., document.baseURI)`，外包 IIFE + `'use strict'`；
3. 写出改写版 `index.html`：经典脚本注入、`fetch → XHR → 原生分块` 三层容错读取 wasm、
   启动进度与错误页、保存/导出接管（`<a download>` → 系统保存选择器）、
   外链接管（`window.open` → 系统浏览器）、宿主配置注入（`window.__VC_WEBGL` / `__VC_LANG`）；
4. `node --check` 自检经典脚本语法。

## 6. 已知坑

- **中文路径**：见第 2 节，构建目录必须全 ASCII。
- **git 依赖慢**：`craft-libs`（workspace 依赖 + `[patch.crates-io]` 的 hayro-*/krilla）
  必须走代理，直接连 github.com 会以几 KB/s 的速度拉取。
- **trunk 的 post_build hook**：`Trunk.toml` 会跑 `cargo xtask web-fonts`，需要 `cargo` 在 PATH 里；
  没有 `CRAFT_FONTS_DIR` 时是空操作。
- **wasm 体积**：release 构建（lto=thin, codegen-units=1）产出的 wasm 约 62 MB，
  与上游发布包同量级；未跑 `wasm-opt`（可选优化）。
