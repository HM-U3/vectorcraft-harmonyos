# 引擎源码备份（鸿蒙原生宿主）

`.so` 是编译产物，源码在这里。改引擎时改**这个目录**，然后跑
`tools/build_engine_native/build_ohos.sh` —— 脚本会把它自动铺进上游源码树。

## 目录

| 路径 | 是什么 | 来源 |
|---|---|---|
| `vectorcraft-ohos/` | 鸿蒙原生宿主 crate（cdylib）：surface 绑定、wgpu/GL 渲染循环、输入转发、系统能力请求队列 | **本项目原创**，上游没有这个目录 |
| `../tools/build_engine_zh/engine-zh.patch` | 引擎侧改动（中文化、品牌、字体、去社区外链） | 本项目对上游打的补丁 |
| `../tools/build_engine_zh/gen_cjk_subset.py` | 生成中文字体子集 `assets/fonts/NotoSansSC-Subset.ttf` | 生成脚本，产物不入库 |
| `../tools/build_engine_native/build_ohos.sh` | 交叉编译 + 投放 `.so` | — |

## 从零重建（换机器 / 源码目录丢失时）

```bash
# 1. 取上游源码（0.16.0）
curl -L -o /tmp/v0.16.0.tar.gz \
  https://gh-proxy.com/https://github.com/storytold/vectorcraft/archive/refs/tags/v0.16.0.tar.gz
mkdir -p /d/vc-build/vc016 && tar xzf /tmp/v0.16.0.tar.gz -C /d/vc-build/vc016

# 2. 打中文化/品牌补丁
cd /d/vc-build/vc016/vectorcraft-0.16.0
git apply <本仓库>/tools/build_engine_zh/engine-zh.patch

# 3. 生成字体子集（也会把字体族改名成 VectorCraft Sans SC）
python <本仓库>/tools/build_engine_zh/gen_cjk_subset.py

# 4. 交叉编译（会自动把 engine/vectorcraft-ohos 铺进 apps/，并写好 .cargo/config.toml）
bash <本仓库>/tools/build_engine_native/build_ohos.sh /d/vc-build/vc016/vectorcraft-0.16.0 --hap
```

## 注意

- **工作区路径必须纯 ASCII**（`/d/vc-build/...`）。MinGW 的 `ld` 处理不了中文路径。
- **`target/` 是编译缓存，删了不影响源码**。删掉后重新编译是全量，约 1–2 小时
  （依赖已缓存在 `~/.cargo/registry`，不用重新下载）。
- 改完引擎代码记得把 `engine/vectorcraft-ohos/` 的改动提交，`apps/` 下那份是编译时的临时副本。

## engine-zh.patch 里到底是什么（0.16.0 基准，4 个文件）

| 文件 | 改了什么 |
|---|---|
| `crates/ui-egui/src/theme.rs` | 挂内嵌 CJK 子集；**并在其后追加 `/system/fonts/HarmonyOS_Sans_SC.ttf`** —— egui 不会自己去系统目录找字，只挂子集的话画布上输入生僻字会空白 |
| `crates/text/src/fontdb.rs` | 导出路径（SVG/PNG）同样兜底到系统字库 |
| `crates/ui-egui/src/chrome.rs` | 品牌名 / 去掉站外社区外链 |
| `crates/ui-egui/src/canvas.rs` | 画布侧的小改动 |

补丁是「上游 0.16.0 → 本工程」的完整差值，**用 `git apply --check` 验证过**。
如果哪次改了源码树里的上游文件却没同步补丁，从零重建就会丢改动；发现补丁打不上时，
按下方办法重新生成（比对基准可以直接用解压出来的干净源码）：

```bash
# 干净源码 vs 当前源码树，只取上游文件（apps/vectorcraft-ohos 由脚本投放，Cargo.lock 由 cargo 重生成）
diff -rq --exclude=target --exclude=vectorcraft-ohos --exclude=.cargo \
     --exclude='NotoSansSC-Subset.ttf' <干净源码> <当前源码树>
```

**`Cargo.lock` 不在补丁里**：宿主 crate 一铺进 `apps/`，cargo 就会把 `napi` 依赖写进 lock；
它在离线缓存齐备时能自动重算，不需要跟着补丁走。
