# 引擎源码备份（鸿蒙原生宿主）

`.so` 是编译产物，源码在这里。改引擎时改**这个目录**，然后跑
`tools/build_engine_native/build_ohos.sh` —— 脚本会把它自动铺进上游源码树。

当前对齐的上游：**v0.24.1**（2026-11-12）。

## 目录

| 路径 | 是什么 | 来源 |
|---|---|---|
| `vectorcraft-ohos/` | 鸿蒙原生宿主 crate（cdylib）：surface 绑定、wgpu/GL 渲染循环、输入转发、系统能力请求队列 | **本项目原创**，上游没有这个目录 |
| `../tools/build_engine_zh/engine-zh.patch` | 引擎侧改动（品牌、去社区外链、系统字库目录） | 本项目对上游打的补丁 |

## 从零重建（换机器 / 源码目录丢失时）

```bash
# 1. 取上游源码
curl -L -o /tmp/v0.24.1.tar.gz \
  https://gh-proxy.com/https://github.com/storytold/vectorcraft/archive/refs/tags/v0.24.1.tar.gz
mkdir -p /d/vc-build/vc024 && tar xzf /tmp/v0.24.1.tar.gz -C /d/vc-build/vc024

# 2. 打鸿蒙适配补丁
cd /d/vc-build/vc024/vectorcraft-0.24.1
git apply <本仓库>/tools/build_engine_zh/engine-zh.patch

# 3. 预拉依赖（0.24 起 egui 等是 git fork，必须先联网拉一次，见下方「git 依赖」）
export PATH="$HOME/.cargo/bin:$PATH"
cd /d/vc-build/vc024/vectorcraft-0.24.1
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch

# 4. 交叉编译（会自动把 engine/vectorcraft-ohos 铺进 apps/，并写好 .cargo/config.toml）
bash <本仓库>/tools/build_engine_native/build_ohos.sh /d/vc-build/vc024/vectorcraft-0.24.1 --hap
```

> `tools/build_engine_zh/gen_cjk_subset.py` 自 0.24 起**不再参与构建**：内嵌中文字体子集那套做法
> 已被上游的「系统字库自动回退」取代，脚本留着备查，编译不再调用。

## 注意

- **工作区路径必须纯 ASCII**（`/d/vc-build/...`）。MinGW 的 `ld` 处理不了中文路径。
- **`target/` 是编译缓存，删了不影响源码**。0.24 全量编译约 40–60 分钟（`lto = "thin"` +
  `codegen-units = 1`，1M 行工作区）。
- **并发别开太高**：`CARGO_BUILD_JOBS=8` 时在本机会卡在两个 host 侧 rustc 上（jobserver 死锁），
  用 `CARGO_BUILD_JOBS=4` 稳。
- 改完引擎代码先改 `engine/vectorcraft-ohos/`，再跑脚本；`apps/` 下那份是编译时的临时副本。

## git 依赖（0.24 起的新情况）

0.24 把 egui / egui-wgpu / winit 换成了 storytold 自己的 fork，另外 craft-libs 也是 git 源。
第一次编译前必须先拉一次，否则离线构建会缺包：

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cd <上游源码树> && env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch
```

拉下来的东西在 `~/.cargo/git/db`（craft-libs / egui / winit），之后 `--offline` 也能用。
**wgpu 仍是 crates.io 的 30.x**，没有跟着换。

## engine-zh.patch 里到底是什么（0.24.1 基准，3 个文件）

| 文件 | 改了什么 |
|---|---|
| `crates/text/src/fontdb/dirs.rs` | `system_font_dirs()` 加 `target_env = "ohos"` 分支指向 `/system/fonts`。不加以会落到 Linux 分支（`/usr/share/fonts`），等于找不到任何已装字体 |
| `crates/ui-egui/src/canvas/home.rs` | 首屏欢迎语改成「矢量工坊」；删掉「社区」区块（Discord 在境内不可访问，外链属站外导流） |
| `crates/ui-egui/src/chrome.rs` | 顶栏不画品牌图标；不显示 Discord 入口 |

> 0.16 时代那两处字体补丁（`theme.rs` 挂内嵌子集 + `fontdb.rs` 兜底）在 0.24 已经**不需要**：
> 上游新增 `crates/ui-egui/src/ui_fonts.rs`，每帧检测 UI 字体缺的字形，后台线程去系统字库找并挂到
> egui 各字体家族末尾。只要 `dirs.rs` 认得 `/system/fonts`，生僻字就有兜底。

补丁是「上游 0.24.1 → 本工程」的完整差值，**用 `git apply --check` 验证过**。
发现补丁打不上时按下方办法重新生成（比对基准用解压出来的干净源码）：

```bash
# 干净源码 vs 当前源码树，只取上游文件（apps/vectorcraft-ohos 由脚本投放，Cargo.lock 由 cargo 重生成）
diff -rq --exclude=target --exclude=vectorcraft-ohos --exclude=.cargo <干净源码> <当前源码树>
```

**`Cargo.lock` 不在补丁里**：宿主 crate 一铺进 `apps/`，cargo 就会把 `napi` 依赖写进 lock；
它在离线缓存齐备时能自动重算，不需要跟着补丁走。
