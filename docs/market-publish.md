# 上架华为应用市场（AppGallery Connect）操作手册

面向本工程（矢量工坊 / `com.vectorcraft.hmos`）。分两部分：**代码与配置**（仓库里能改的）
和 **AGC 流程**（只能在网页后台做的）。

> 每次改完代码准备发版，先跑一次体检：
> ```
> python tools/check-market-ready.py
> ```
> 它会把「会不会被 AGC 拦下 / 会不会被审核驳回」的静态问题全部列出来。

---

## 一、代码与配置：本工程已处理项

| 项 | 上架要求 | 本工程状态 |
| --- | --- | --- |
| 应用名 | 不得使用他人商标 | 「矢量工坊」，已脱离上游名 |
| 应用图标 | 1024×1024，满幅方形，不能自带圆角白边 | 已重建为满幅渐变底 + 白色贝塞尔曲线 |
| 引擎内品牌标 | 不得出现上游品牌标识 | 已在 `chrome.rs` 加 `wasm32` 条件，重编译后不绘制 |
| 引擎首页 | 名称需与应用一致；不得含失效外链 | 首页标题改为「矢量工坊」，并移除「社区」区块（Discord 境内不可访问、其余三个外链属站外导流）；应用栏与「关于」里的 Discord 入口同步移除 |
| 权限 | 只申请实际使用的权限 | 已删除 `INTERNET` / `GET_NETWORK_INFO`（引擎全本地加载，代码里无任何网络请求） |
| 应用内隐私说明 | AGC 要求可查看 | 帮助页新增「隐私说明」章节 |
| 开发向文案 | 面向用户的页面不能出现调试说明 | 帮助页已移除 DevEco / 签名 / 日志相关内容 |
| vendor | 开发者主体，不是上游项目名 | 改为 `HM-U3` |
| 开源许可 | MIT / Apache-2.0 需保留声明 | 帮助页「版本与许可」+ 仓库 LICENSE / NOTICE |

## 二、代码与配置：还需要你做的

### 1. 发布证书与 Profile（唯一的硬性阻断项）

现在 `build-profile.json5` 里是 **DevEco 自动生成的调试签名**（`keyAlias: debugKey`，
证书/Profile 是 `~/.ohos/config/default_*.cer/.p7b`）。它带设备白名单，**AGC 不接受**。

在 AGC 网页端依次做：

1. **用户与访问控制 → 证书、APP ID 和 Profile**
2. **证书管理 → 新增证书**：选「发布证书」，生成密钥与 CSR（或在本地用 DevEco 生成），
   上传 CSR，下载得到 `xxx.cer`
3. **Profile 管理 → 新增 Profile**：类型选**发布**，选上一步的证书和应用，下载 `xxx.p7b`
4. 本地 `.p12` / `.cer` / `.p7b` 三件套与口令**另外备份**——丢证书后同一包名无法正常升级，
   要走 AGC 的证书恢复流程

然后在 DevEco：`File → Project Structure → Signing Configs`，取消勾选
`Automatically generate signature`，手动填入：

- Store file：`xxx.p12`
- Store password / Key alias / Key password
- Profile file：`xxx.p7b`
- Certpath：`xxx.cer`

保存后 `build-profile.json5` 会写成这样（`products[0].signingConfig` 必须存在，
**只写 `signingConfigs` 不绑定会打出未签名 HAP，安装报 9568320**）：

```json5
"signingConfigs": [
  {
    "name": "release",
    "type": "HarmonyOS",
    "material": {
      "storeFile": "C:\\keys\\vectorcraft.p12",
      "storePassword": "……",
      "keyAlias": "vectorcraft",
      "keyPassword": "……",
      "profile": "C:\\keys\\vectorcraftRelease.p7b",
      "certpath": "C:\\keys\\vectorcraft.cer",
      "signAlg": "SHA256withECDSA"
    }
  }
],
"products": [
  { "name": "default", "signingConfig": "release", /* ... */ }
]
```

> 签名的 `.p12` / `.p7b` / 口令**不要**提交到公开仓库。本工程的
> `tools/local-signing.py off` 会把当前签名配置备份到 `build-profile.local-signing.json5`
> （已 gitignore）并清空，`on` 再原样还原。

**⚠️ 换成发布签名后，本地装不了机。** 用 hdc 或 DevEco Run 安装会报
`code:9568322 error: signature verification failed due to not trusted app source` ——
这是正常的：发布证书由 AGC 签发，只有从应用市场安装才被设备信任，本地调试装不进去。

要在真机继续测，按这个循环走：

```bash
python tools/local-signing.py off    # 备份发布签名并清空 → DevEco 里重新「自动签名」（调试档）
# ……真机调试……
python tools/local-signing.py on     # 还原发布签名，再出 release 包提审
```

### 2. 打 release 包

DevEco：`Build → Build Hap(s)/APP(s) → Build APP(s)`，`Build Mode` 选 `release`。
命令行等价：

```bash
# 工程根目录执行
node "D:/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --mode project -p product=default -p buildMode=release assembleApp --no-daemon
```

产物：`build/outputs/default/*.app`（AGC 上传这个，不是 `entry/build` 下的 hap）。

### 3. 包名是否要改（建议现在决定）

`com.vectorcraft.hmos` 里带了上游项目名。开源的 MIT/Apache-2.0 **只给代码许可，不给商标许可**，
包名和展示名里长期使用他人产品名，理论上存在被投诉的可能。

- 已上架后包名**不可更改**，只能下架重建；
- 如果还没在 AGC 建应用，建议改成 `com.hmu3.vectorcraft` 之类以自己为主体的形式；
- 如果要改，`docs/technical-notes.md` 里记录了需要同步的位置（`AppScope/app.json5` 一处）。

---

## 三、AGC 流程（网页端）

### 1. 新建应用

- 我的应用 → 新建应用 → 平台选 **HarmonyOS**
- 应用名称：**矢量工坊**
- 包名：与 `AppScope/app.json5` 的 `bundleName` **完全一致**
- 分类建议：「实用工具」下的图形/设计类（按后台可选分类为准）
- 默认语言：简体中文

### 2. 软件包上传

版本管理 → 新建版本 → 上传第 2 步打出的 `.app`。
AGC 会校验：包名一致、签名证书与 Profile 匹配、`versionCode` 大于历史版本。

### 3. 应用信息与素材

| 素材 | 要求 |
| --- | --- |
| 应用图标 | 1024×1024 PNG，**不要自带圆角**（已处理） |
| 应用截图 | 每种设备类型（手机 / 平板 / 2in1）各 3–5 张；平板建议 2560×1600 以上；不要黑边、不要拼接。`docs/screenshots/native/` 已放四张平板实机图（原生渲染版：首页、新建文档、最近文件面板、关于），可直接补足数量 |
| 一句话简介 | 按表单字数上限填写，突出「离线矢量插画编辑」 |
| 应用介绍 | 说明功能、导出格式、完全离线；**不要**把 VectorCraft 写成自己的产品，可写「基于开源 VectorCraft 引擎」 |
| 隐私政策 URL | 必填。用 `docs/privacy-policy.html` 托管（见下） |
| 内容分级 | 按问卷填写；无用户生成内容分发、无社交功能，通常为最低年龄档 |
| 版权/资质 | 非游戏，不需要版号 |

### 4. 隐私政策托管

`docs/privacy-policy.md` 与 `docs/privacy-policy.html` 已按本工程实际行为写好
（不收集信息、无网络请求、无权限、数据只在本机）。托管方式二选一：

- **GitHub Pages**：把 `privacy-policy.html` 放进公开仓库 `docs/` 目录 →
  Settings → Pages → Source 选 `main` / `/docs` → 得到
  `https://hm-u3.github.io/vectorcraft-harmonyos/privacy-policy.html`
- 任意可公开访问的静态托管（对象存储、语雀公开文档等）

把该链接同时填到 AGC 的「隐私政策」字段。

### 5. 应用备案（中国大陆强制）

2023 年 9 月起，国内分发的 App 必须完成**移动互联网应用程序备案**，未备案无法上架。
AGC 有「应用备案」入口，提交：主体证件、应用信息（包名、公钥、签名 MD5）、承诺书等。
**需要先有发布证书**（公钥和签名 MD5 来自它），所以顺序是：证书 → 备案 → 提审。
个人开发者可以备案；审核周期通常数个工作日到三周不等，建议尽早提交。

### 6. 提审

提交后华为审核通常 1–3 个工作日。本项目可能被问到的点，预先准备好答案：

- **首次启动十几秒**：68 MB 引擎要从 rawfile 读入内存并编译 WASM，有进度条遮罩，
  不会白屏。介绍里写清「首次启动需要初始化引擎」。
- **为什么没申请任何权限**：本来就全部本地运行，可直接回答。
- **是否收集个人信息**：不收集，隐私政策第一条已写明。
- **与 VectorCraft 的关系**：第三方开源移植，非官方，已在帮助页与介绍中声明。
- **包里为什么有 `.wasm` 文件**：编辑引擎由 Rust 编译为 WebAssembly，**随安装包一起分发、运行时从
  rawfile 读取，不会从网络下载或热更新**（应用也未申请网络权限，物理上无法联网）。

### 7. 可直接复制的商店文案

**一句话简介**

> 完全离线的矢量插画编辑器，支持 SVG / PDF / PNG 导出，专为平板与二合一优化。

**应用介绍**

> 矢量工坊是一款在设备本地运行的矢量插画编辑器：所有绘制、编辑与导出都在本机完成，
> 不需要登录，不需要联网，也不收集任何个人信息。
>
> · 完整矢量编辑：贝塞尔路径、节点编辑、布尔运算、渐变、文字与图层
> · 常见画布预设：A4、信纸、Web 1920×1080、手机 390×844、社交方图等
> · 多格式导出：SVG、PDF、PNG、JPEG、WebP，以及可继续编辑的 .vectorcraft 工程文件
> · 最近文件：保存过的作品会留在应用内，退出后重新打开即可继续编辑
> · 三端自适应：手机、平板、鸿蒙电脑上自动切换侧栏 / 顶栏 / 底栏布局
>
> 编辑引擎基于开源项目 VectorCraft（MIT / Apache-2.0）构建，本应用为其第三方移植版本，
> 与原作者无隶属关系。引擎、字体与图标全部内嵌在安装包内，应用运行时不发起任何网络请求。

---

## 四、发版检查清单

```
[ ] python tools/check-market-ready.py 全绿（WARN 逐条确认）
[ ] 发布证书 .cer / Profile .p7b / keystore .p12 已备份到仓库外
[ ] build-profile.json5 的 signingConfig 已绑到 products[0]
[ ] Build APP(s) + release 模式，产物是 build/outputs/default/*.app
[ ] AGC 包名与 app.json5 bundleName 一致
[ ] versionCode 大于 AGC 上最后一个版本
[ ] 图标 / 截图 / 隐私政策 URL / 备案号 已填
[ ] 真机安装 release 包跑一遍：启动、画一条路径、保存、最近文件、重启后打开
```
