#!/usr/bin/env python3
"""提交前自查：扫掉不该进仓库的本机信息。

build-profile.json5 一旦在 DevEco 里勾过「自动签名」，就会被写回本机用户目录下的
绝对路径与加密口令 —— 这样的版本不要提交。本脚本命中任一项即以退出码 1 结束。

用法：
    python tools/check-before-publish.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 签名配置相关键与证书后缀
SECRET_PATTERNS = [
    (re.compile(r'"signingConfigs"\s*:\s*\[\s*\{'), "build-profile.json5 含签名配置（应留空，由各机器本地的 DevEco 生成）"),
    (re.compile(r'"storePassword"'), "storePassword"),
    (re.compile(r'"keyPassword"'), "keyPassword"),
    (re.compile(r'"keyAlias"'), "keyAlias"),
    (re.compile(r'"certpath"'), "certpath"),
    (re.compile(r'"profile"\s*:\s*"[^"]*\.p7b"'), "profile 证书路径"),
    (re.compile(r'"storeFile"\s*:\s*"[^"]*\.p12"'), "storeFile 证书路径"),
]

# 本机绝对路径（用户目录）
ABS_PATH_PATTERNS = [
    (re.compile(r'[A-Za-z]:\\\\Users\\\\[^"\\\s]+'), "Windows 用户目录绝对路径"),
    (re.compile(r'[A-Za-z]:/[Uu]sers/[^"\\\s]+'), "Windows 用户目录绝对路径（正斜杠）"),
    (re.compile(r'/home/[a-z]'), "Linux home 绝对路径"),
    (re.compile(r'/Users/[a-z]'), "macOS Users 绝对路径"),
]

# 需要扫描的文件（文本类）
TEXT_SUFFIXES = {".json5", ".json", ".ts", ".ets", ".md", ".txt", ".html", ".js", ".py", ".properties"}

# 明确允许的例外（本脚本自身的模式定义行）
ALLOWED_SUBSTRINGS = [
    "check-before-publish.py",
]

# 本脚本自身的文件名：其中的正则模式字符串不算命中
SELF_NAME = Path(__file__).name


def main() -> int:
    hits = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        if path.name == SELF_NAME:
            continue
        if path.suffix not in TEXT_SUFFIXES:
            continue
        rel = path.relative_to(ROOT)
        parts = set(rel.parts)
        if parts & {"node_modules", "oh_modules", "build", ".git", ".hvigor", ".idea"}:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for pattern, label in SECRET_PATTERNS + ABS_PATH_PATTERNS:
            for m in pattern.finditer(text):
                line_no = text.count("\n", 0, m.start()) + 1
                snippet = text.splitlines()[line_no - 1].strip()[:100]
                if any(a in snippet for a in ALLOWED_SUBSTRINGS):
                    continue
                # 文档中的命令行示例（D:\DevEco Studio\...）属说明性质，单独放宽
                if rel.suffix == ".md" and ("export DEVECO_SDK_HOME" in snippet or "hvigorw.js" in snippet):
                    continue
                hits.append(f"{rel}:{line_no}: [{label}] {snippet}")

    if hits:
        print("命中以下项目，请手动清理后再提交：\n")
        for h in hits:
            print("  " + h)
        print(f"\n共 {len(hits)} 处。")
        return 1
    print("OK：未发现签名配置、口令或本机绝对路径。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
