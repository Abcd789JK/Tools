#!/usr/bin/env bash
# --------------------------------------------------
# name   : sync-mihomo.sh
# desc   : 以 beta 通道为唯一源，生成正式版脚本
# date   : 2026-11-22 12:58:00
# author : ChatGPT JK789
# ver    : 1.0.0
# --------------------------------------------------

# 唯一源是 mihomo_beta/，本脚本把它"翻译"成正式版 mihomo/。
# 两个通道的差异仅允许是：版本号（去掉 -beta 后缀）与仓库路径（去掉 _beta）。
# 维护流程：只改 beta → 跑本脚本 → 校验通过后才覆盖正式版。

# 必须用 bash 运行：dash/sh 不支持 [[ ]] 与数组。
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' '错误：请使用 bash 运行本脚本' >&2
    exit 1
fi

set -Eeuo pipefail

# 仓库根目录 = 本脚本所在目录，保证从任意 cwd 调用都正确。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly SRC_DIR="${ROOT_DIR}/mihomo_beta"
readonly DST_DIR="${ROOT_DIR}/mihomo"
readonly -a FILES=(install.sh mihomo.sh)

# 临时目录统一由 EXIT Trap 回收，不遗留半成品。
TMP_DIR=""
cleanup() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

log_info() { printf '%s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# 从源脚本头部读取版本号，并推导正式版版本号（去掉 -beta 后缀）。
resolve_versions() {
    local header_ver const_ver

    header_ver="$(awk '/^# ver[[:space:]]*:/ { v=$0; sub(/^# ver[[:space:]]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }' \
        "${SRC_DIR}/mihomo.sh")"
    const_ver="$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "${SRC_DIR}/mihomo.sh")"

    [[ -n "$header_ver" ]] || die "无法从 ${SRC_DIR}/mihomo.sh 读取头部 ver"
    [[ -n "$const_ver" ]] || die "无法从 ${SRC_DIR}/mihomo.sh 读取 SCRIPT_VERSION"
    [[ "$header_ver" == "$const_ver" ]] || die "beta 源版本号不一致（头部 ${header_ver}，常量 ${const_ver}）"
    [[ "$const_ver" == *-beta ]] || die "beta 版本号 '${const_ver}' 未以 -beta 结尾，拒绝生成"

    readonly SRC_VERSION="$const_ver"
    readonly STABLE_VERSION="${const_ver%-beta}"
    log_info "[INFO] 源版本 ${SRC_VERSION} → 正式版 ${STABLE_VERSION}"
}

# 生成候选文件到临时目录：只替换版本号与仓库路径两处。
generate_candidates() {
    local f
    for f in "${FILES[@]}"; do
        [[ -f "${SRC_DIR}/${f}" ]] || die "缺少源文件 ${SRC_DIR}/${f}"
        sed -e "s/${SRC_VERSION}/${STABLE_VERSION}/g" \
            -e 's#mihomo_beta#mihomo#g' \
            "${SRC_DIR}/${f}" > "${TMP_DIR}/${f}"
    done
}

# 把两个文件里的版本号与路径归一化，用于反向比对。
normalize() { # $1=文件
    sed -e 's/[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-beta/VER/g' \
        -e 's/[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/VER/g' \
        -e 's#mihomo_beta#mihomo#g' \
        "$1"
}

# 校验候选：语法、行尾、版本号一致性、路径无残留、与源规范化后完全一致。
verify_candidates() {
    local f header_ver const_ver diff_out

    for f in "${FILES[@]}"; do
        bash -n "${TMP_DIR}/${f}" 2>/dev/null || die "${f} 语法校验失败"

        # 行尾必须是 LF：统计 \r 字节数。
        [[ "$(tr -cd '\r' < "${TMP_DIR}/${f}" | wc -c)" -eq 0 ]] \
            || die "${f} 含 CRLF 行尾"

        header_ver="$(awk '/^# ver[[:space:]]*:/ { v=$0; sub(/^# ver[[:space:]]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }' "${TMP_DIR}/${f}")"
        const_ver="$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "${TMP_DIR}/${f}")"
        [[ "$header_ver" == "$STABLE_VERSION" ]] || die "${f} 头部版本 ${header_ver} ≠ ${STABLE_VERSION}"
        [[ "$const_ver" == "$STABLE_VERSION" ]] || die "${f} 常量版本 ${const_ver} ≠ ${STABLE_VERSION}"

        # 正式版不得残留 beta 路径。
        grep -n 'mihomo_beta' "${TMP_DIR}/${f}" && die "${f} 残留 mihomo_beta 路径"

        # 反向校验：归一化后必须与源完全一致，确保没有任何额外改动。
        if ! diff_out="$(diff -u <(normalize "${SRC_DIR}/${f}") <(normalize "${TMP_DIR}/${f}") 2>&1)"; then
            printf '%s\n' "$diff_out" >&2
            die "${f} 与 beta 源存在预期外差异"
        fi
    done
    log_info "[INFO] 校验通过：语法 / LF / 版本一致 / 路径无残留 / 源文件一致"
}

# 校验全部通过后再覆盖正式版，避免出现"生成了一半"的状态。
install_candidates() {
    local f
    for f in "${FILES[@]}"; do
        cp -f -- "${TMP_DIR}/${f}" "${DST_DIR}/${f}" || die "写入 ${DST_DIR}/${f} 失败"
    done
}

main() {
    [[ -d "$SRC_DIR" ]] || die "缺少源目录 ${SRC_DIR}"
    [[ -d "$DST_DIR" ]] || die "缺少目标目录 ${DST_DIR}"

    TMP_DIR="$(mktemp -d "${ROOT_DIR}/.sync-mihomo.XXXXXX")" || die "无法创建临时目录"

    resolve_versions
    generate_candidates
    verify_candidates
    install_candidates

    log_info "[ OK ] 已同步正式版 ${STABLE_VERSION}（${#FILES[@]} 个文件）"
}

main "$@"
