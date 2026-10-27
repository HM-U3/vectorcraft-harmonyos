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
