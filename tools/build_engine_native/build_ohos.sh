#!/usr/bin/env bash
# 交叉编译鸿蒙原生引擎，并把 libvectorcraft_native.so 放进本工程。
#
#   bash tools/build_engine_native/build_ohos.sh <VectorCraft Rust 源码目录> [选项]
#
# 选项：
#   --app <目录>   要投放 .so 的鸿蒙工程（默认：本仓库根目录）
#   --hap          投放后再跑一次 hvigor assembleHap
#   --debug        编 debug 而不是 release
#
# 环境变量：
#   OHOS_SDK   DevEco SDK 的 openharmony 目录
#              （默认 "D:/ohsdk/default/openharmony"；D:/ohsdk 是指向 "D:/DevEco Studio/sdk"
#               的目录联接，SDK 路径带空格会让 cc-rs 把 --sysroot 切碎）
#   HVIGOR     hvigorw 路径（默认 "D:/DevEco Studio/tools/hvigor/bin/hvigorw.bat"）
set -euo pipefail

APP="$(cd "$(dirname "$0")/../.." && pwd)"
SRC=""
DO_HAP=0
PROFILE=release

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --hap) DO_HAP=1; shift ;;
    --debug) PROFILE=debug; shift ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) SRC="$1"; shift ;;
  esac
done

if [[ -z "$SRC" ]]; then
  echo "用法: bash tools/build_engine_native/build_ohos.sh <VectorCraft Rust 源码目录> [--hap]" >&2
  exit 2
fi
SRC="$(cd "$SRC" && pwd)"

SDK="${OHOS_SDK:-D:/ohsdk/default/openharmony}"
HVIGOR="${HVIGOR:-D:/DevEco Studio/tools/hvigor/bin/hvigorw.bat}"
TARGET=aarch64-unknown-linux-ohos
NDK="$SDK/native"

if [[ ! -d "$NDK/sysroot" ]]; then
  echo "错误：在 $SDK 下找不到 NDK（native/sysroot）。请设置 OHOS_SDK。" >&2
  exit 1
fi

# 目标链接器必须写进源码树的 .cargo/config.toml（cargo 只认这一处，环境变量
# CC_* 只管 C 依赖的编译）。换机器时路径不同，这里按当前 OHOS_SDK 覆盖该块。
write_cargo_config() {
  local cfg="$SRC/.cargo/config.toml"
  mkdir -p "$SRC/.cargo"
  if [[ -f "$cfg" ]] && grep -q "^\[target.aarch64-unknown-linux-ohos\]" "$cfg"; then
    echo "==> .cargo/config.toml 已含 HarmonyOS 目标块，保持不变（如路径变了请删掉该块后重跑）"
    return
  fi
  cat >> "$cfg" <<EOF

# HarmonyOS 原生目标（本机 DevEco SDK 路径）
[target.aarch64-unknown-linux-ohos]
linker = "$NDK/llvm/bin/clang"
rustflags = [
    "-Clink-arg=--target=aarch64-linux-ohos",
    "-Clink-arg=--sysroot=$NDK/sysroot",
    "-Clink-arg=-D__MUSL__",
    "-Clink-arg=-fuse-ld=lld",
    "-Clink-arg=-lnative_window",
    "-Clink-arg=-lhilog_ndk.z",
]
EOF
  echo "==> 已写入 $cfg 的 HarmonyOS 目标块"
}

write_cargo_config

# 宿主 crate 随本仓库一起维护（engine/vectorcraft-ohos），编译前铺进上游源码树。
# 上游没有这个目录 —— 它是本项目新写的，所以必须从这里同步过去，改代码也改这边。
HOST="$(cd "$(dirname "$0")/../.." && pwd)/engine/vectorcraft-ohos"
if [[ -d "$HOST" ]]; then
  echo "==> 铺设宿主 crate → $SRC/apps/vectorcraft-ohos"
  mkdir -p "$SRC/apps/vectorcraft-ohos"
  cp -R "$HOST/." "$SRC/apps/vectorcraft-ohos/"
else
  echo "警告：找不到 $HOST，将沿用源码树里现有的 apps/vectorcraft-ohos" >&2
fi

if ! rustup target list --installed | grep -qx "$TARGET"; then
  echo "==> 安装 Rust 目标 $TARGET"
  rustup target add "$TARGET"
fi

export OHOS_NDK_HOME="$SDK"
export CC_aarch64_unknown_linux_ohos="$NDK/llvm/bin/clang"
export AR_aarch64_unknown_linux_ohos="$NDK/llvm/bin/llvm-ar"
export CXX_aarch64_unknown_linux_ohos="$NDK/llvm/bin/clang++"
export CFLAGS_aarch64_unknown_linux_ohos="--sysroot=$NDK/sysroot -D__MUSL__"

# Git Bash 下 PATH 里没有 cargo/rustup，补一条（Windows 的 rustup 装在 ~/.cargo/bin）
if ! command -v cargo >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

echo "==> cargo build -p vectorcraft-ohos ($PROFILE, $TARGET)"
cd "$SRC"
if [[ "$PROFILE" == "release" ]]; then
  cargo build -p vectorcraft-ohos --release --target "$TARGET"
  OUT="$SRC/target/$TARGET/release"
else
  cargo build -p vectorcraft-ohos --target "$TARGET"
  OUT="$SRC/target/$TARGET/debug"
fi

SO="$OUT/libvectorcraft_native.so"
echo "==> 产出 $(wc -c < "$SO") 字节"

DEST="$APP/entry/libs/arm64-v8a"
mkdir -p "$DEST"
cp "$SO" "$DEST/"
echo "==> 已投放 $DEST/libvectorcraft_native.so"

if [[ "$DO_HAP" == "1" ]]; then
  echo "==> hvigor assembleHap"
  ( cd "$APP" && DEVECO_SDK_HOME="$(dirname "$SDK")" HOS_SDK_HOME="$(dirname "$SDK")" \
      "$HVIGOR" --mode module -p product=default assembleHap --no-daemon )
fi
