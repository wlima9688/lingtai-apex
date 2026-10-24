#!/bin/bash
# 闪控 · build_flash.sh — 编译 flash（热键面板）
#
# ⚠ 为什么用合并编译而不是把 Args 抄一份到 flash.swift：
#   Args 是 macctl.swift 里的通用参数解析器。复制一份意味着两份实现会漂移
#   ——改了 macctl 的忘了改 flash 的，症状是「同样的参数两个命令行为不同」，
#   极难排查。所以直接把 Args 的源码抽出来一起编译。
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 从 macctl.swift 抽出 Args 的定义（含其依赖的行）
/usr/bin/python3 - "$DIR" <<'PY' > /tmp/flash_args.swift
import io, re, sys, os
d = sys.argv[1]
s = io.open(os.path.join(d, "macctl.swift"), encoding="utf-8").read()
m = re.search(r"^struct Args \{.*?^\}\n", s, re.M | re.S)
if not m:
    sys.stderr.write("❌ 没在 macctl.swift 里找到 struct Args\n")
    sys.exit(1)
sys.stdout.write(m.group(0))
PY

# ⚠ 拼接时每段之间必须保留换行：任一源文件末尾缺换行，
#   两个声明会被粘成一行 → "consecutive statements on a line"（踩过）
# flash_archive.swift 是「工业档案画风」的视图组件（底板/卡片/准星），
#   单独成文件是为了不让 flash.swift（已 1200+ 行）继续膨胀。
#
# ⚠ 文件清单只在这里维护一次：selftest 的「反向验证」（注入 bug 版再编译，
#   证明像素判据抓得到错）需要用**同一份清单**换掉 flash_archive.swift，
#   它曾经自己抄了一份 → 加了 flash_earth_data / flash_handoff 后没跟上，
#   编译必失败、反向验证静默失守（2026-10-22 自检抓到）。所以下面开放三个
#   环境变量覆写：FLASH_ARCHIVE_SRC / FLASH_OUT / FLASH_CONCAT。
# ⚠ 拼接线**只写一条字面量清单**，不要引入变量/分支：
#   ① selftest 的「几何自检反证」会正则解析这一行来复现构建；
#   ② selftest 的「反向验证」（注入 bug 版 archive 再编译，证明像素判据
#      抓得到错）也解析同一行、只把 flash_archive.swift 换成坏版。
#   曾经有一版在这里加了 $ARCHIVE 变量和 if/else 两个分支 —— 前者让 ② 解析
#   不到 archive，后者让 ① 拿到重复文件、编译报重复声明（2026-10-22 连挂两项）。
#   所以清单保持单行字面量，覆写能力放在解析侧，不放在这里。
{ cat "$DIR/flashkit.swift"; echo; cat /tmp/flash_args.swift; echo; cat "$DIR/flash_earth_data.swift"; echo; cat "$DIR/flash_archive.swift"; echo; cat "$DIR/flash_handoff.swift"; echo; cat "$DIR/flash.swift"; } > /tmp/flash_all.swift
/usr/bin/swiftc -O -o "$DIR/flash" /tmp/flash_all.swift 2>&1 | grep -E "error:" && exit 1
echo "✅ flash 编译完成"

# ⚠ 编译完**立刻重签**：重编译会丢掉签名，而 ad-hoc 签名的「指定要求」是
#   cdhash —— 一变，TCC 的辅助功能授权就作废（用户又得重新勾一次，而且
#   期间会被系统弹窗骚扰）。用固定自签证书重签后，指定要求变成
#   `identifier + 证书根`，跨重编译稳定。
bash "$DIR/flashctl.sh" sign >/dev/null 2>&1 \
  && echo "   已重签（Shankong Local Signer）—— 辅助功能授权可跨重编译保留" \
  || echo "   ⚠️ 重签失败：本次是 ad-hoc 签名，辅助功能授权可能需要重新勾一次"
