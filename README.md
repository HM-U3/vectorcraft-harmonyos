# 矢量工坊 · VectorCraft for HarmonyOS

[![upstream](https://img.shields.io/badge/upstream-storytold%2Fvectorcraft-2f81f7?logo=github&logoColor=white)](https://github.com/storytold/vectorcraft)
[![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-3da639)](LICENSE-MIT)
[![platform](https://img.shields.io/badge/platform-HarmonyOS%205%2B-0a59f7)](https://developer.huawei.com/consumer/cn/)
[![engine](https://img.shields.io/badge/engine-WebAssembly-654ff0?logo=webassembly&logoColor=white)](docs/technical-notes.md)

> 把开源矢量插画编辑器 **[VectorCraft](https://github.com/storytold/vectorcraft)**（Rust → WebAssembly）装进
> **HarmonyOS 5+** 的客户端。引擎跑在 ArkWeb 里，外面套一层原生鸿蒙外壳 ——
> 鸿蒙平板与鸿蒙电脑（2in1）都可用，界面已完整中文化。

---

## 一、这是什么

- **上游**：VectorCraft 是 ArtCraft 团队用纯 Rust 编写的开源矢量插画编辑器，
  Adobe Illustrator 的工作流平替（Pen / 路径 / Pathfinder / 渐变网格 / 封套扭曲等）。
  通过 `egui` + `wgpu` 渲染，编译成 WebAssembly 后在浏览器中运行；
  原生支持 macOS / Windows / Linux / FreeBSD。上游目前仍处于 **alpha** 阶段
  （其自评约为 Illustrator 功能面的 69–75%）。
- **本工程**：把它移植到鸿蒙。Web 组件（ArkWeb）负责加载并运行引擎，原生 ArkTS 提供
  侧栏 / 顶栏 / 底栏、渲染后端切换、保存与导出、外部链接处理、内置使用说明等能力。
- **中文化**：不止是外壳。引擎是从上游源码**重新编译**的 —— 默认加载上游官方简体中文
  语言包（`zh-hans`）并内嵌中文字体子集，编辑器内部的菜单、工具名与提示同样是中文。

> ⚠️ **非官方适配**
>
> 本工程与上游 VectorCraft / ArtCraft 团队**没有隶属或背书关系**，是第三方移植。
> 上游本身仍是 alpha，**请勿用于生产工作流**。

## 二、功能

| 类别 | 说明 |
|---|---|
| 编辑能力 | 钢笔、直接选择、路径布尔（Pathfinder）、渐变、渐变网格、封套扭曲、重复、透视网格等，与上游 Web 版一致 |
| 文件 | 新建 / 打开 `.vectorcraft`（JSON）工程；导入 SVG、PDF、`.ai`、位图等 |
| 保存导出 | 调用系统「保存到」选择器，保存完成后提示完整文件路径；导出 SVG / PDF / PNG / JPEG / WebP |
| 最近文件 | 保存后自动登记（最多 12 条，重启不丢），列表内一点即可重新打开；副本留在应用沙箱 |
| 渲染后端 | 应用内切换 自动（WebGPU→WebGL2）/ WebGL2，选择结果持久化 |
| 输入方式 | 鼠标、触摸、手写笔 |
| 界面语言 | 默认简体中文，可在引擎「首选项 › 界面 › 语言」切回英文等其它语言 |

## 三、界面适配

界面随窗口宽度自动切换形态，拖拽窗口实时生效：

| 形态 | 判定条件 | 原生外壳 |
|---|---|---|
| 鸿蒙电脑 / 二合一（2in1） | 窗口宽 ≥ 840vp | 左侧竖向侧栏（展开 216vp，收起为 64vp 图标条） |
| 鸿蒙平板 | 600vp ≤ 宽 < 840vp | 顶部工具栏（48vp） |
| 鸿蒙手机 / 小窗 | 宽 < 600vp | 底部悬浮胶囊按钮组 |

编辑区始终是**同一个 Web 组件实例**，切换形态只改变其内边距 ——
不会因为拖动窗口而重新加载六十多 MB 的引擎。

## 四、环境要求

| 项 | 要求 |
|---|---|
| 目标系统 | HarmonyOS 5.0（API 12）及以上 |
| 设备类型 | `phone` / `tablet` / `2in1` |
| 开发工具 | DevEco Studio 6.1.1（hvigor 6.24.4 下验证通过） |
| 第三方依赖 | 无，`oh-package.json5` 为空，Sync 不需要联网装包 |

> 引擎本体 `.wasm` 约 62 MB，已直接放在仓库里（未用 Git LFS，clone 即可用）。

## 五、快速开始

### 1. 获取代码

```bash
git clone https://github.com/HM-U3/vectorcraft-harmonyos.git vectorcraft
cd vectorcraft
```

### 2. 用 DevEco Studio 打开

1. `File → Open…`，选择**本仓库目录本身**（不要选它的父目录）。
2. 首次打开 IDE 会自动 Sync 一次；本工程无第三方依赖，不需要联网装包。
3. 配置签名（仅首次，用于安装到真机或模拟器）：
   `File → Project Structure → Signing Configs` → 勾选 **Automatically generate signature**
   → 登录华为账号 → `Apply`。IDE 会把 `signingConfig` 写回 `build-profile.json5`
   （**该改动不要提交**，提交前跑一次 `python tools/check-before-publish.py`）。
4. 选择设备（系统需 **HarmonyOS 5.0 / API 12** 及以上），点击 ▶ Run。

> 只做编译验证的话：`Build → Build Hap(s)/APP(s) → Build Hap(s)`，不配签名也能产出 HAP。

### 3. 命令行构建（可选）

```bash
export DEVECO_SDK_HOME="D:\\DevEco Studio\\sdk"
"D:\\DevEco Studio\\tools\\node\\node.exe" \
  "D:\\DevEco Studio\\tools\\hvigor\\bin\\hvigorw.js" \
  assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
```

## 六、目录结构

```
vectorcraft-harmonyos/
├── AppScope/                            应用级配置（bundleName / 版本 / 图标）
├── entry/                               主模块（HAP）
│   └── src/main/
│       ├── module.json5                 deviceTypes: phone / tablet / 2in1
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets   入口：状态初始化、页面加载、窗口尺寸监听
│       │   ├── common/Constants.ets            常量与渲染后端枚举
│       │   ├── common/ResourceBridge.ets       javaScriptProxy 桥（配置下发 / 状态回调 / 资源兜底 / 保存 / 外链）
│       │   ├── common/RecentStore.ets          最近文件：Preferences + 沙箱副本，持久化保存记录
│       │   ├── pages/Index.ets                 主页面：ArkWeb + 自适应原生外壳
│       │   └── pages/Help.ets                  内置「使用说明」页
│       └── resources/
│           ├── base/media/                     应用图标（分层图）与界面 SVG 图标
│           ├── dark/element/color.json         深色主题色
│           └── rawfile/vectorcraft/           ← 引擎资源
│               ├── index.html                       已改写：加载容错 + 进度 + 错误页 + 保存/外链接管
│               ├── vectorcraft-web-<hash>.classic.js 经典脚本胶水层（鸿蒙实际加载的）
│               ├── vectorcraft-web-<hash>.js         上游 ESM 胶水层（保留备查）
│               └── vectorcraft-web-<hash>_bg.wasm    中文引擎本体（约 62 MB）
├── tools/
│   ├── build_engine_zh/                 引擎重编译配方（不参与打包）
│   │   ├── README.md                    完整步骤 + 已知坑
│   │   ├── engine-zh.patch              相对上游的全部改动
│   │   ├── gen_cjk_subset.py            Noto Sans SC 子集化
│   │   └── fonts/LICENSE-NotoSansSC.txt Noto Sans SC 的 OFL 1.1 许可
│   ├── pack_web.py                      trunk 产物 → rawfile 打包 + ESM 转经典脚本
│   └── check-before-publish.py          提交前自查（签名路径、口令、本机绝对路径）
├── LICENSE-MIT / LICENSE-APACHE
├── hvigor/hvigor-config.json5           hvigor 配置（modelVersion 必须与 oh-package.json5 一致）
└── build-profile.json5 / hvigorfile.ts / oh-package.json5 / code-linter.json5
```

## 七、渲染后端

| 后端 | 说明 |
|---|---|
| 自动（默认） | 优先 WebGPU，不可用时回落到 WebGL2 |
| WebGL2 | 兼容性最好，平板与手机推荐 |

切换入口在侧栏 / 顶栏 / 底栏的「渲染后端」，选择后引擎自动重启，设置跨启动保持。

## 八、实现要点

移植过程中主要解决的是「浏览器里能跑、鸿蒙 Web 组件里跑不起来」这一类差异。简单说：

1. **引擎加载三层容错** —— `resource://rawfile` 协议下各设备对 `fetch` / `XHR` 的支持不一致，
   页面依次尝试 `fetch` → `XMLHttpRequest` → 原生分块通道（ArkTS 读 rawfile 后按 1 MiB base64 回传）。
   三层都失败时显示错误详情，并提供「重新加载 / 改用 WebGL2」入口。
2. **胶水层改用经典脚本** —— ArkWeb 的 ES Module 加载器不支持 `resource://`，
   于是把 `wasm-bindgen` 的 ESM 胶水层等价转换成经典脚本内联注入，不改动引擎逻辑。
3. **宿主配置经 window 全局变量下发** —— 引擎的 `?webgl` / `?lang=` 依赖 `location.search`，
   而 `resource://` 页面无法改写自己的查询串；鸿蒙外壳的渲染后端选项因此改为经
   `window.__VC_WEBGL` / `__VC_LANG` 注入（引擎侧对应补丁读取这两个全局变量）。
4. **中文字体与语言** —— 引擎从源码重编译：内嵌 Noto Sans SC 子集（已改名避开 OFL 保留字体名）、
   默认简体中文界面；子集覆盖全部上游 i18n 词条表用字。
5. **保存 / 导出与外链** —— 引擎原本依赖浏览器的 `<a download>` 与 `window.open`，
   ArkWeb 两者都不处理。现在由 `index.html` 拦下并转交原生：保存走系统选择器，
   外链交给系统浏览器，编辑器页面不会被顶掉。

上述每一条的**现象、根因、验证数据**都会随迭代记录在 [`docs/technical-notes.md`](docs/technical-notes.md)。

## 九、已知限制

- 上游是 alpha，功能完整度与稳定性以上游为准；崩溃请先确认在上游 Web 版是否同样出现。
- 首次启动需把约 62 MB 引擎读入内存并编译，耗时十几秒到几十秒，属正常现象。
- 内嵌中文字体是子集（覆盖全部界面用字），文字图层里输入生僻字可能显示空白。
- 浏览器打印（File → Print）在鸿蒙 Web 组件内可能不可用，需要打印时请先导出 PDF。
- 手机形态（< 600vp）已适配但测试较少；主要验证环境是鸿蒙平板与鸿蒙电脑。
- 启动失败时优先在应用内切换渲染后端；日志可在 DevEco 的 Log 面板搜 `[VectorCraft]` 查看。

## 十、常见问题

**Q：打开工程报「hvigor 配置的 modelVersion（未配置）与 ohpm 配置的 modelVersion(6.1.0) 不一致」**

工程根目录必须有 `hvigor/hvigor-config.json5`，其中 `modelVersion` 要与根 `oh-package.json5`
的 `modelVersion` **完全一致**（允许范围 5.0.0 ~ 6.1.1）。本仓库两处都写 `6.1.0`，
对应 DevEco Studio 6.1.x / hvigor 6.24.4。若本机 IDE 版本不同，两个文件要一起改：

```json5
// hvigor/hvigor-config.json5
{ "modelVersion": "6.1.0", /* ... */ }

// oh-package.json5
{ "modelVersion": "6.1.0", /* ... */ }
```

改完执行 `File → Sync Project with Hvigor`（命令行等价于 `hvigorw --sync`）即可。

**Q：编译报 `Argument of type 'Alignment' is not assignable to parameter of type 'HorizontalAlign'`**

`Column.alignItems()` 的交叉轴是水平方向，只接受 `HorizontalAlign`；`Alignment` 只能用于
`Stack.alignContent()` 或通用 `.align()`。本工程已在 2026-10-17 全面修正。

## 十一、许可与署名

- 本工程沿用上游的 **MIT / Apache-2.0 双许可**（二选一）：
  [`LICENSE-MIT`](LICENSE-MIT) 、 [`LICENSE-APACHE`](LICENSE-APACHE)。
- 上游 [VectorCraft](https://github.com/storytold/vectorcraft) 同为 MIT / Apache-2.0 双许可。
- `VectorCraft` / `ArtCraft` 名称与标识为上游团队的商标，本工程仅作非商业性适配使用。
- `rawfile/vectorcraft/` 下的引擎本体（`.wasm` / `.js`）是**从上游 Rust 源码重新编译**的产物，
  相对上游源码只做了最小改动（中文字体、默认语言、宿主配置注入），
  补丁见 `tools/build_engine_zh/engine-zh.patch`。
- `index.html` 为适配鸿蒙改写了加载逻辑，未改动引擎内部行为。
- 中文字体 **Noto Sans SC**（SIL Open Font License 1.1）以子集形式内嵌并已改名
  （`VectorCraft Sans SC`），许可原文见 `tools/build_engine_zh/fonts/LICENSE-NotoSansSC.txt`。

## 十二、致谢

- [storytold/vectorcraft](https://github.com/storytold/vectorcraft) —— 上游引擎
- [egui](https://github.com/emilk/egui) / [wgpu](https://github.com/gfx-rs/wgpu) / [wasm-bindgen](https://github.com/rustwasm/wasm-bindgen) —— 引擎所依赖的生态
- **Noto Sans SC** —— Google，SIL Open Font License 1.1
- 移植方法参考姊妹工程 [PhotoCraft for HarmonyOS](https://github.com/HM-U3/photocraft-harmonyos)
