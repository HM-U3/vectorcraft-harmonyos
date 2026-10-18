#!/usr/bin/env python3
"""本地签名开关。

build-profile.json5 同时承担两个互相冲突的角色：
  * 开源仓库里它必须是干净的（signingConfigs 为 []），否则会把本机证书路径
    和加密后的口令一起提交上去；
  * 装真机时它必须指向本机生成的证书，且 products 里要绑定签名配置。

DevEco 的「自动签名」只会写 signingConfigs 数组，**不会**写 products[0] 的
`"signingConfig": "default"` 绑定 —— 缺这一行，打包产物是未签名 HAP，
安装报 `9568320 no signature file`。本脚本把这两件事一起管掉。

用法：
    python tools/local-signing.py off      # 提交前：备份并清空签名配置
    python tools/local-signing.py on       # 装真机前：恢复签名并补上绑定
    python tools/local-signing.py status   # 查看当前状态
"""

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROFILE = ROOT / "build-profile.json5"
BACKUP = ROOT / "build-profile.local-signing.json5"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def dump(path: Path, data: dict) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def cmd_off() -> int:
    data = load(PROFILE)
    sigs = data.get("app", {}).get("signingConfigs") or []
    if not sigs:
        print("当前已是无签名状态，无需处理。")
        return 0
    shutil.copy2(PROFILE, BACKUP)
    data["app"]["signingConfigs"] = []
    for prod in data["app"].get("products", []):
        prod.pop("signingConfig", None)
    dump(PROFILE, data)
    print(f"已清除签名配置。原文件备份到 {BACKUP.name}（已被 .gitignore 忽略）")
    print("现在可以放心提交了，例如：git add -A && git commit")
    return 0


def cmd_on() -> int:
    if not BACKUP.exists():
        print(f"找不到 {BACKUP.name}。")
        print("请先在 DevEco Studio 里点一次 File > Project Structure > Signing Configs")
        print("勾选 Automatically generate signature 并 Apply。")
        return 1
    shutil.copy2(BACKUP, PROFILE)
    data = load(PROFILE)
    sigs = data.get("app", {}).get("signingConfigs") or []
    if not sigs:
        print("备份里也没有签名配置，请在 DevEco 里重新自动签名。")
        return 1
    name = sigs[0].get("name", "default")
    missing = [
        prod
        for prod in data["app"].get("products", [])
        if prod.get("signingConfig") != name
    ]
    if missing:
        for prod in missing:
            prod["signingConfig"] = name
        dump(PROFILE, data)
        print(f"已恢复签名配置，并补上 products 绑定（signingConfig: {name}）")
    else:
        print("已恢复签名配置（绑定原本就在）。")
    return 0


def cmd_status() -> int:
    data = load(PROFILE)
    sigs = data.get("app", {}).get("signingConfigs") or []
    products = data.get("app", {}).get("products", [])
    bound = [p.get("signingConfig") for p in products]

    if not sigs:
        print("签名配置: 无（仓库可提交状态）")
    else:
        names = ", ".join(s.get("name", "?") for s in sigs)
        print(f"签名配置: {len(sigs)} 个（{names}）—— 提交前请执行 off")
    print(f"products 绑定: {bound}")
    if sigs and not any(bound):
        print("⚠ 有证书但 products 未绑定 → 打包会产出未签名 HAP（9568320）")
        print("  执行 `python tools/local-signing.py on` 可自动补上")
    print(f"备份文件: {'存在' if BACKUP.exists() else '不存在'}")
    return 0


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    table = {"off": cmd_off, "on": cmd_on, "status": cmd_status}
    if action not in table:
        print(__doc__)
        return 2
    return table[action]()


if __name__ == "__main__":
    sys.exit(main())
