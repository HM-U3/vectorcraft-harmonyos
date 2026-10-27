#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
上架体检 —— 在提交华为应用市场（AppGallery Connect）之前跑一遍。

只做静态检查：读工程配置与资源，判断「会不会被 AGC 拦下来 / 会不会被审核驳回」。
不修改任何文件，不联网，不依赖第三方库。

用法：
    python tools/check-market-ready.py            # 在当前目录（工程根）执行
    python tools/check-market-ready.py --strict   # WARN 也视为未通过（退出码 1）

退出码：0 全部通过（允许有 WARN）；1 存在 FAIL（或 --strict 下有 WARN）。
"""

import io
import json
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RESULTS = []  # (level, title, detail, fix)


def add(level, title, detail="", fix=""):
    RESULTS.append((level, title, detail, fix))


def read(path):
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return None
    with io.open(full, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def json5(text):
    """够用的 json5 → dict：去注释、去尾逗号。"""
    if text is None:
        return None
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    try:
        return json.loads(text)
    except Exception as exc:  # noqa: BLE001
        add("FAIL", "配置无法解析", str(exc))
        return None


# ---------------------------------------------------------------- PNG 工具


def png_info(path):
    """返回 (宽, 高, 位深, 颜色类型, 首行像素函数)。只解不压缩的第一行。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos = 8
    width = height = depth = ctype = interlace = None
    idat = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype_chunk = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype_chunk == b"IHDR":
            width, height, depth, ctype, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif ctype_chunk == b"IDAT":
            idat += body
        elif ctype_chunk == b"IEND":
            break
        pos += 12 + length
    if not width:
        return None
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype, 4)
    bpp = channels * (depth // 8)
    stride = width * bpp
    try:
        raw = zlib.decompress(idat)
    except Exception:  # noqa: BLE001
        return width, height, depth, ctype, None
    if interlace != 0 or depth != 8:
        return width, height, depth, ctype, None
    flt = raw[0]
    line = bytearray(raw[1:1 + stride])
    if flt == 1:
        for i in range(bpp, stride):
            line[i] = (line[i] + line[i - bpp]) & 0xFF
    elif flt == 2 or flt == 3 or flt == 4:
        # 首行 prev 全 0，filter 2/3/4 退化为 1/2/原值，这里做保守近似
        for i in range(bpp, stride):
            line[i] = (line[i] + line[i - bpp]) & 0xFF

    def pixel(x):
        idx = x * bpp
        if ctype == 6:
            return tuple(line[idx:idx + 4])
        if ctype == 2:
            return tuple(line[idx:idx + 3]) + (255,)
        return (0, 0, 0, 255)

    return width, height, depth, ctype, pixel


# ---------------------------------------------------------------- 各项检查


def check_app_scope():
    cfg = json5(read("AppScope/app.json5"))
    if not cfg:
        add("FAIL", "缺少 AppScope/app.json5", "", "恢复该文件，否则无法打出安装包")
        return None
    app = cfg.get("app", {})
    bundle = app.get("bundleName", "")
    if not re.match(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$", bundle):
        add("FAIL", "bundleName 不合规", bundle, "建议反向域名写法，如 com.hmu3.vectorworks")
    else:
        add("PASS", "bundleName", bundle)
    if "vectorcraft" in bundle:
        add("WARN", "bundleName 含上游名 vectorcraft",
            bundle,
            "bundleName 上架后不可更改。若担心商标争议，现在改成自己的域名（如 com.hmu3.xxx），"
            "并在 AGC 用新包名创建应用")

    vendor = app.get("vendor", "")
    if vendor.lower() in ("vectorcraft", "artcraft", "storytold"):
        add("FAIL", "vendor 用的是上游项目名", vendor, "改成开发者主体名称")
    elif not vendor:
        add("WARN", "缺少 vendor", "", "填开发者主体名称")
    else:
        add("PASS", "vendor", vendor)

    vcode = app.get("versionCode")
    vname = app.get("versionName")
    if not isinstance(vcode, int) or vcode < 1:
        add("FAIL", "versionCode 无效", str(vcode), "整数，首次上架建议 1000000")
    else:
        add("PASS", "versionCode", str(vcode))
    if not vname:
        add("FAIL", "缺少 versionName", "", "如 1.0.0")
    else:
        add("PASS", "versionName", vname)
    return app


def check_build_profile(app):
    cfg = json5(read("build-profile.json5"))
    if not cfg:
        add("FAIL", "缺少 build-profile.json5")
        return
    body = cfg.get("app", {})
    products = body.get("products", [])
    signing = body.get("signingConfigs", [])

    # 1. 签名档
    if not signing:
        add("FAIL", "未配置签名", "signingConfigs 为空",
            "上架包必须有签名。AGC → 证书管理 生成发布证书与发布 Profile 后，"
            "在 DevEco Project Structure → Signing Configs 里配好")
    else:
        for item in signing:
            material = item.get("material", {})
            alias = str(material.get("keyAlias", ""))
            profile = str(material.get("profile", ""))
            store = str(material.get("storeFile", ""))
            is_debug = (
                "debug" in alias.lower()
                or "\\config\\default_" in profile
                or "/config/default_" in profile
                or os.path.basename(profile).startswith("default_")
            )
            if is_debug:
                add("FAIL", "当前是调试签名（不可上架）",
                    "alias=%s profile=%s" % (alias, os.path.basename(profile)),
                    "调试证书带设备白名单且 AGC 不认。换成发布证书 .cer + 发布 Profile .p7b "
                    "（创建时类型选 release / 发布），并把 keyAlias 换成自己的别名")
            if re.search(r"[A-Za-z]:\\\\|/Users/|/home/", store + profile):
                add("WARN", "签名配置含本机绝对路径",
                    (store or profile)[:80],
                    "上架包不受影响，但这台机器之外无法构建；不要把这个文件提交到公开仓库")
            if "0000" in str(material.get("storePassword", ""))[:8]:
                add("WARN", "签名口令以密文形式写在本机配置里",
                    "", "不要提交到仓库；换机器要重新配签名")

    # 2. product 绑定
    bound = False
    for p in products:
        if p.get("signingConfig"):
            bound = True
    if signing and not bound:
        add("FAIL", "签名没绑定到 product",
            "products[0] 缺少 signingConfig",
            "只写 signingConfigs 不会生效，必须加 \"signingConfig\": \"default\"，"
            "否则打出未签名 HAP（安装报 9568320）")
    elif signing and bound:
        add("PASS", "签名已绑定到 product")

    # 3. release 构建模式
    modes = [m.get("name") for m in body.get("buildModeSet", [])]
    if "release" in modes:
        add("PASS", "存在 release 构建模式")
    else:
        add("FAIL", "缺少 release 构建模式", str(modes), "上架必须用 release 构建")

    # 4. SDK 版本
    for p in products:
        tgt = str(p.get("targetSdkVersion", ""))
        cmp_ = str(p.get("compatibleSdkVersion", ""))
        if app:
            tgt_num = re.search(r"\((\d+)\)", tgt)
            app_tgt = app.get("targetAPIVersion")
            if tgt_num and app_tgt and int(tgt_num.group(1)) != int(app_tgt):
                add("FAIL", "targetAPIVersion 与 build-profile 不一致",
                    "app.json5=%s / build-profile=%s" % (app_tgt, tgt),
                    "两处必须相同，否则打出的包元数据自相矛盾")
        add("PASS", "SDK 版本", "compatible=%s target=%s" % (cmp_, tgt))


def check_module():
    cfg = json5(read("entry/src/main/module.json5"))
    if not cfg:
        add("FAIL", "缺少 entry/src/main/module.json5")
        return
    module = cfg.get("module", {})
    perms = module.get("requestPermissions", [])
    if perms:
        names = "、".join(p.get("name", "?").replace("ohos.permission.", "") for p in perms)
        add("WARN", "声明了 %d 个权限" % len(perms), names,
            "逐个确认确有必要。离线的本地编辑器申请 INTERNET / GET_NETWORK_INFO 会被判超范围，"
            "建议删除（本项目已验证删除后功能正常）")
    else:
        add("PASS", "未声明任何权限")

    abilities = module.get("abilities", [])
    if not abilities:
        add("FAIL", "缺少 abilities")
    for ab in abilities:
        if ab.get("exported") and not ab.get("skills"):
            add("WARN", "ability 对外导出但未声明 skills", ab.get("name", ""))
    add("PASS", "设备类型", "、".join(module.get("deviceTypes", [])))


def check_icons():
    app_icon = "AppScope/resources/base/media/app_icon.png"
    full = os.path.join(ROOT, app_icon)
    if not os.path.exists(full):
        add("FAIL", "缺少应用图标", app_icon, "AppScope 下必须有 1024x1024 的 app_icon.png")
        return
    info = png_info(full)
    if not info:
        add("FAIL", "图标不是合法 PNG", app_icon)
        return
    width, height, depth, ctype, pixel = info
    if (width, height) != (1024, 1024):
        add("WARN", "图标尺寸不是 1024x1024", "%dx%d" % (width, height))
    if pixel:
        corner = pixel(0)
        if ctype in (2, 6) and corner[3] < 250:
            add("WARN", "图标四角透明", str(corner),
                "如需系统圆角，应做满幅方形底图，让系统自己裁")
        elif corner[:3] == (255, 255, 255):
            add("FAIL", "图标自带白底圆角", "左上角像素 (255,255,255)",
                "系统会再裁一次圆角，四角会露出白边。改用满幅方形底图（背景铺满 1024，不画圆角）")
        else:
            add("PASS", "图标满幅无白边", "左上角 %s" % (corner[:3],))
    for extra in ("foreground.png", "background.png", "layered_image.json"):
        p = "AppScope/resources/base/media/" + extra
        if not os.path.exists(os.path.join(ROOT, p)):
            add("WARN", "缺少分层图标素材", p, "鸿蒙主题图标需要分层素材，建议补齐")


def check_sources():
    ets_dir = os.path.join(ROOT, "entry/src/main/ets")
    dev_words = re.compile(r"DevEco|Signing Configs|no signature file|hvigor|hdc |Project Structure")
    hits = []
    for base, _dirs, files in os.walk(ets_dir):
        for name in files:
            if not name.endswith(".ets"):
                continue
            path = os.path.join(base, name)
            with io.open(path, "r", encoding="utf-8", errors="replace") as f:
                for no, line in enumerate(f, 1):
                    stripped = line.strip()
                    # 只看会显示给用户的字符串；注释与日志不算
                    if stripped.startswith(("//", "*", "/*")):
                        continue
                    if dev_words.search(line) and "console." not in line:
                        hits.append("%s:%d" % (os.path.relpath(path, ROOT).replace("\\", "/"), no))
    if hits:
        add("FAIL", "界面文案里残留开发向说明", "、".join(hits[:6]),
            "面向用户的帮助页不要出现 DevEco / 签名 / 命令行；审核看到会认为工程未收尾")
    else:
        add("PASS", "界面无开发向文案")

    help_text = read("entry/src/main/ets/pages/Help.ets") or ""
    if "隐私" in help_text:
        add("PASS", "应用内可查看隐私说明")
    else:
        add("FAIL", "应用内没有隐私说明", "",
            "AGC 要求填写隐私政策链接；应用内也应有入口，审核会点开看")
    if "许可" in help_text:
        add("PASS", "应用内标注开源许可")
    else:
        add("WARN", "应用内未标注开源许可", "", "MIT/Apache-2.0 要求保留版权与许可声明")


def check_resources():
    # 原生渲染版：引擎是 entry/libs/arm64-v8a/libvectorcraft_native.so，不再有 rawfile wasm
    so = "entry/libs/arm64-v8a/libvectorcraft_native.so"
    if not os.path.exists(os.path.join(ROOT, so)):
        add("FAIL", "缺少原生引擎库", so, "引擎缺失，安装后无法使用")
    else:
        size = os.path.getsize(os.path.join(ROOT, so))
        add("PASS" if size > 10 * 1024 * 1024 else "WARN",
            "原生引擎库", "libvectorcraft_native.so %.1f MB" % (size / 1048576.0))
    # Web 壳套应当已经移除：残留 rawfile 引擎会白白撑大安装包
    web = "entry/src/main/resources/rawfile/vectorcraft"
    if os.path.isdir(os.path.join(ROOT, web)):
        add("WARN", "仍残留 Web 壳套 rawfile", web, "原生渲染不需要，删掉可减小安装包")
    pages = json5(read("entry/src/main/resources/base/profile/main_pages.json"))
    if pages:
        missing = [p for p in pages.get("src", [])
                   if not os.path.exists(os.path.join(ROOT, "entry/src/main/ets", p + ".ets"))]
        if missing:
            add("FAIL", "页面文件缺失", "、".join(missing))
        else:
            add("PASS", "页面清单与源文件一致")


def check_hygiene():
    if os.path.exists(os.path.join(ROOT, "build-profile.local-signing.json5")):
        add("WARN", "存在本机签名备份文件",
            "build-profile.local-signing.json5",
            "里面是证书路径与加密口令，已 gitignore；对外分发工程目录前删掉")
    gitignore = read(".gitignore") or ""
    for key in ("build-profile.local-signing.json5", "build", ".idea"):
        if key not in gitignore:
            add("WARN", ".gitignore 未忽略 %s" % key)
    if os.path.isdir(os.path.join(ROOT, ".git")):
        cfg = read(".git/config") or ""
        m = re.search(r"url = (\S+)", cfg)
        if m and "vectorcraft-harmonyos" in m.group(1):
            add("WARN", "工程副本仍指向公开仓库", m.group(1),
                "上架副本里会带上签名口令与本机路径，误 push 会公开。建议 git remote remove origin，"
                "或换一个私有 remote")


# ---------------------------------------------------------------- 输出


def main():
    strict = "--strict" in sys.argv
    app = check_app_scope()
    check_build_profile(app)
    check_module()
    check_icons()
    check_sources()
    check_resources()
    check_hygiene()

    order = {"FAIL": 0, "WARN": 1, "PASS": 2}
    RESULTS.sort(key=lambda r: order.get(r[0], 3))
    mark = {"FAIL": "[未通过]", "WARN": "[注意]", "PASS": "[通过]"}
    for level, title, detail, fix in RESULTS:
        line = "%s %s" % (mark[level], title)
        if detail:
            line += "：" + detail
        print(line)
        if fix and level != "PASS":
            print("         → " + fix)
    fails = sum(1 for r in RESULTS if r[0] == "FAIL")
    warns = sum(1 for r in RESULTS if r[0] == "WARN")
    print("")
    print("通过 %d 项，注意 %d 项，未通过 %d 项。" % (
        sum(1 for r in RESULTS if r[0] == "PASS"), warns, fails))
    if fails:
        print("有未通过项，先修完再打包上架。")
        return 1
    if warns and strict:
        print("--strict：注意项也会阻止上架。")
        return 1
    print("静态检查已通过。剩下的流程项（发布证书 / 备案 / 素材）见 docs/market-publish.md。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
