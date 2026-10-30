#!/usr/bin/env bash
# HARMONY_TOOLS_HOME 指向官方 Command Line Tools；本机也可指向 DevEco Studio/Contents。
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${HARMONY_TOOLS_HOME:?需要匹配工程的官方 HarmonyOS 命令行工具}"
tools="$HARMONY_TOOLS_HOME"
export DEVECO_SDK_HOME="$tools/sdk"
export PATH="$tools/bin:$tools/tools/node/bin:$tools/node/bin:$PATH"
hvigor="$tools/bin/hvigorw"
ohpm="$tools/bin/ohpm"
[ -x "$hvigor" ] || hvigor="$tools/tools/hvigor/bin/hvigorw"
[ -x "$ohpm" ] || ohpm="$tools/tools/ohpm/bin/ohpm"
"$ohpm" install --all
"$hvigor" --mode module -p product=default -p module=entry@default -p buildMode=release assembleHap --no-daemon
mkdir -p build/release
cp entry/build/default/outputs/default/entry-default-unsigned.hap build/release/MovieClaw-HarmonyOS-unsigned.hap
python3 scripts/release/metadata.py inspect build/release/MovieClaw-HarmonyOS-unsigned.hap
