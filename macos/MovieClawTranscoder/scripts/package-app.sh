#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MovieClaw 转码器.app"
OUTPUT_DIR="${PROJECT_DIR}/dist"
APP_DIR="${OUTPUT_DIR}/${APP_NAME}"
SIGNING_IDENTITY="${MOVIECLAW_SIGNING_IDENTITY:--}"

swift build --package-path "${PROJECT_DIR}" -c release
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${PROJECT_DIR}/.build/release/movieclaw-transcoder" "${APP_DIR}/Contents/MacOS/movieclaw-transcoder"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
# App 图标：Finder、访达信息面板、⌘Tab 切换器都读它（CFBundleIconFile）
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# 版本号：转码器独立发版（transcoder-vX.Y.Z），唯一来源是 Resources/Info.plist 的
# CFBundleShortVersionString，发新版前递增它。BuildInfo 读它并在握手时上报给服务端。
# MOVIECLAW_WORKER_VERSION 只用于临时覆盖（如打测试包），改的是 bundle 里的拷贝而非
# 源文件，不弄脏工作区；必须在 codesign 之前做（签名封存 Info.plist）。
if [ -n "${MOVIECLAW_WORKER_VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "${MOVIECLAW_WORKER_VERSION}" \
        "${APP_DIR}/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "${MOVIECLAW_WORKER_VERSION}" \
        "${APP_DIR}/Contents/Info.plist"
    echo "已注入版本号：${MOVIECLAW_WORKER_VERSION}"
fi

# 校正二进制里记录的「链接所用 SDK 版本」（LC_BUILD_VERSION 的 sdk 字段）。
#
# SwiftPM 的新构建系统（swiftbuild，Xcode 27 起默认）链接时把部署目标 12.0 当成
# SDK 版本写进去，旧的 native 构建系统写的是真实版本（同一台机器实测：swiftbuild
# 写 12.0、native 写 27.0）。系统按这个字段判断 App「用哪版 SDK 链接」来决定新
# 行为是否生效：写成 12.0，macOS 26 起菜单、按钮、窗口的液态玻璃新外观一律不
# 启用，其它按 SDK 版本开关的行为也全退回 macOS 12 时代。代码确实是对着当前 SDK
# 编译的，这里改回真实值；同样必须在 codesign 之前（改完原签名即失效）。
BINARY="${APP_DIR}/Contents/MacOS/movieclaw-transcoder"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
BUILD_INFO="$(xcrun vtool -show-build "${BINARY}")"
MIN_OS="$(awk '$1 == "minos" { print $2; exit }' <<<"${BUILD_INFO}")"
RECORDED_SDK="$(awk '$1 == "sdk" { print $2; exit }' <<<"${BUILD_INFO}")"
if [ -n "${MIN_OS}" ] && [ -n "${SDK_VERSION}" ] && [ "${RECORDED_SDK}" != "${SDK_VERSION}" ]; then
    xcrun vtool -set-build-version macos "${MIN_OS}" "${SDK_VERSION}" \
        -replace -output "${BINARY}" "${BINARY}"
    echo "已把链接 SDK 版本从 ${RECORDED_SDK:-未知} 校正为 ${SDK_VERSION}（最低系统 ${MIN_OS} 不变）"
fi

# 由内向外逐个签，不用 --deep。
#
# --deep 已被 Apple 标为不推荐：它对嵌套内容套用同一套参数，签出来的结果和
# 「各自按各自的规则签」并不等价，公证阶段常见的疑难杂症有一半出在这儿。
# 这个 bundle 只有一个可执行文件，手工排两行比 --deep 更清楚也更可控。
SIGN_ARGS=(--force --options runtime)
if [ "${SIGNING_IDENTITY}" = "-" ]; then
    # ad-hoc 签名不需要也用不了可信时间戳，别为它去连 Apple 的时间戳服务器
    SIGN_ARGS+=(--timestamp=none)
else
    # 公证要求签名带可信时间戳
    SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" --sign "${SIGNING_IDENTITY}" \
    "${APP_DIR}/Contents/MacOS/movieclaw-transcoder"
codesign "${SIGN_ARGS[@]}" --sign "${SIGNING_IDENTITY}" "${APP_DIR}"

echo "已生成：${APP_DIR}"

# 公证（可选）：Developer ID 签名之后交给 Apple 公证，再把公证票据钉进 bundle
# （staple），用户下载后双击即可打开，不再被 Gatekeeper 拦下、也不用联网现查。
#
# 凭证二选一，都不给就跳过公证：
#   - MOVIECLAW_NOTARY_PROFILE：本机用 `xcrun notarytool store-credentials <名字>`
#     存进钥匙串的凭证名，适合手工发版；
#   - MOVIECLAW_NOTARY_KEY_PATH / _KEY_ID / _ISSUER：App Store Connect API 密钥
#     （.p8 文件路径、密钥 ID、Issuer ID），发版流水线用这一种。
# 公证只认 Developer ID 签名；ad-hoc 签名配了公证凭证属于配置错误，直接报错，
# 免得发出去一个以为公证过、其实没有的包。
NOTARIZE=0
if [ -n "${MOVIECLAW_NOTARY_PROFILE:-}" ]; then
    NOTARIZE=1
    NOTARY_AUTH=(--keychain-profile "${MOVIECLAW_NOTARY_PROFILE}")
elif [ -n "${MOVIECLAW_NOTARY_KEY_PATH:-}" ]; then
    NOTARIZE=1
    NOTARY_AUTH=(--key "${MOVIECLAW_NOTARY_KEY_PATH}"
        --key-id "${MOVIECLAW_NOTARY_KEY_ID:?配置了 MOVIECLAW_NOTARY_KEY_PATH 但缺少 MOVIECLAW_NOTARY_KEY_ID}"
        --issuer "${MOVIECLAW_NOTARY_ISSUER:?配置了 MOVIECLAW_NOTARY_KEY_PATH 但缺少 MOVIECLAW_NOTARY_ISSUER}")
fi

if [ "${NOTARIZE}" = "1" ]; then
    if [ "${SIGNING_IDENTITY}" = "-" ]; then
        echo "错误：配置了公证凭证，但当前是 ad-hoc 签名。公证要求 Developer ID 签名，" >&2
        echo "      请同时设置 MOVIECLAW_SIGNING_IDENTITY=\"Developer ID Application: …\"。" >&2
        exit 1
    fi
    NOTARY_DIR="$(mktemp -d)"
    trap 'rm -rf "${NOTARY_DIR}"' EXIT
    # 提交的是 zip：公证服务不收裸 .app 目录。票据要钉在 .app 上，所以这个 zip
    # 只用于提交，最终发布的 zip 由调用方在 staple 之后重新打
    ditto -c -k --keepParent "${APP_DIR}" "${NOTARY_DIR}/submit.zip"
    echo "正在提交 Apple 公证（通常几分钟，最长等 60 分钟）…"
    # 结果为 Invalid 时 --wait 的退出码不一定非零，以 JSON 里的 status 为准
    RESULT="$(xcrun notarytool submit "${NOTARY_DIR}/submit.zip" "${NOTARY_AUTH[@]}" \
        --wait --timeout 60m --output-format json 2>"${NOTARY_DIR}/stderr")" || true
    STATUS="$(plutil -extract status raw -o - - <<<"${RESULT}" 2>/dev/null || true)"
    SUBMISSION_ID="$(plutil -extract id raw -o - - <<<"${RESULT}" 2>/dev/null || true)"
    if [ "${STATUS}" != "Accepted" ]; then
        echo "错误：Apple 公证没有通过（状态：${STATUS:-提交失败}）。" >&2
        cat "${NOTARY_DIR}/stderr" >&2
        if [ -n "${RESULT}" ]; then echo "${RESULT}" >&2; fi
        if [ -n "${SUBMISSION_ID}" ]; then
            echo "公证日志（逐条列出被拒的文件与原因）：" >&2
            xcrun notarytool log "${SUBMISSION_ID}" "${NOTARY_AUTH[@]}" >&2 || true
        fi
        exit 1
    fi
    xcrun stapler staple "${APP_DIR}"
    # 按用户机器上 Gatekeeper 的口径复核：签名与公证票据都认，才算能双击打开
    spctl --assess --type execute --verbose=2 "${APP_DIR}"
    echo "已公证并钉入票据（提交 ID：${SUBMISSION_ID}）"
fi

if [ "${SIGNING_IDENTITY}" = "-" ]; then
    cat >&2 <<'WARN'

⚠️  这是 ad-hoc 签名（没有 Developer ID），发行前请补上正式签名。

    ad-hoc 签名没有证书，系统只能拿二进制的 cdhash 当这个 App 的身份，
    而 cdhash **每次重新构建都会变**。后果是钥匙串：Worker 令牌那条记录的
    访问控制表认的是创建它的那个身份，换了一份构建就成了「另一个程序」，
    于是每装一次新版本都会弹窗要一次钥匙串密码（点「始终允许」只在同一份
    二进制没变时有效）。

    正式签名：
        MOVIECLAW_SIGNING_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
            scripts/package-app.sh
    再给出公证凭证（MOVIECLAW_NOTARY_PROFILE，或 MOVIECLAW_NOTARY_KEY_PATH /
    _KEY_ID / _ISSUER），脚本会自动公证，别人的机器上才能直接双击打开。
WARN
elif [ "${NOTARIZE}" = "0" ]; then
    cat >&2 <<'WARN'

⚠️  已用 Developer ID 签名，但没有公证：别人下载后首次打开仍会被系统拦下。
    发行前请给出公证凭证（MOVIECLAW_NOTARY_PROFILE，或 MOVIECLAW_NOTARY_KEY_PATH /
    _KEY_ID / _ISSUER）重新打包。
WARN
fi
