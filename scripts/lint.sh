#!/bin/bash
# 闪控 · lint.sh — 路由表与 scripts/ 双向一致性校验
#
# 规格书 FR-4：路由表是唯一事实源。scripts/ 里每个脚本必须在表中有条目，反之亦然。
# 本脚本对「故意制造的漂移」100% 报错。
#
# 检查项：
#   1. scripts/*.sh 每个都在 SKILL.md 路由表中被提及
#   2. SKILL.md 路由表中提到的每个 .sh 都真实存在
#   3. 每个脚本可执行、语法正确（bash -n）
#   4. 每个脚本都 source 了 common.sh
#   5. SKILL.md 行数 ≤ 150（规格书硬约束）
#   6. manifest.json 合法 JSON 且 entry 存在
#
# 退出：0 = 通过；1 = 有漂移

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
MANIFEST="$SKILL_DIR/manifest.json"

ERRORS=0
err() { echo "✗ $1"; ERRORS=$((ERRORS+1)); }
ok()  { echo "✓ $1"; }

echo "=== 闪控 lint ==="

# ── 1. scripts/ 每个脚本都在路由表中 ─────────────────────────────
echo "--- 1. scripts/ → 路由表 ---"
# common.sh 是公共库不是意图脚本，不占路由条目
SKIP_ROUTE="common.sh"
shopt -s nullglob
SCRIPTS=("$DIR"/*.sh)
# 工具脚本：不是业务动作，不需要进路由表、不需要 emit/audit 契约。
#   selftest/lint 是自检工具，bench 是性能验收工具 —— 它们输出给人看，不是模型消费的 JSON。
# flashctl.sh 是「常驻服务的管理器」（装/卸开机自启、看状态），
#   不是业务意图脚本 —— 它的输出是给人看的状态文本，没有 JSON 契约，
#   也不该出现在路由表里让模型去调用。
# build_flash.sh 是「编译脚本」（swiftc 编译 flash 二进制），
#   既不是业务意图、也不产出 JSON 契约 —— 和 selftest/lint/bench 同类工具。
# bootctl.sh 是「开场动画开机自启的管理器」（装/卸 LaunchAgent、看状态），
#   与 flashctl.sh 同类：输出是给人看的状态文本，没有 JSON 契约，
#   也不该出现在路由表里让模型去调用。
TOOLS="selftest.sh lint.sh bench.sh common.sh flashctl.sh build_flash.sh bootctl.sh"
if [ ${#SCRIPTS[@]} -eq 0 ]; then
  err "scripts/ 下没有任何 .sh 脚本"
else
  for f in "${SCRIPTS[@]}"; do
    b="$(basename "$f")"
    case " $TOOLS " in *" $b "*) continue ;; esac
    if grep -qF "$b" "$SKILL_MD"; then
      ok "$b 在路由表中"
    else
      err "$b 未出现在 SKILL.md 路由表中 —— 模型永远发现不了它"
    fi
  done
fi

# ── 2. 路由表提到的脚本都存在 ──────────────────────────────────
echo "--- 2. 路由表 → scripts/ ---"
# 从 SKILL.md 抽取所有 `xxx.sh` 形式的文件名
# 排除占位符（xxx / example / your_script 等），它们只是文档示例
MENTIONED="$(grep -oE '[A-Za-z0-9_-]+\.sh' "$SKILL_MD" \
  | grep -vE '^(xxx|example|your_script|new_script|todo|placeholder)\.sh$' \
  | sort -u)"
if [ -z "$MENTIONED" ]; then
  err "SKILL.md 里没有提到任何 .sh 脚本"
else
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    if [ -f "$DIR/$b" ]; then
      ok "$b 存在"
    else
      err "SKILL.md 提到 ${b}，但该文件不存在"
    fi
  done <<< "$MENTIONED"
fi

# ── 3. 可执行 + 语法正确 ───────────────────────────────────────
echo "--- 3. 语法与权限 ---"
for f in "${SCRIPTS[@]}"; do
  b="$(basename "$f")"
  if bash -n "$f" 2>/dev/null; then
    ok "$b 语法正确"
  else
    err "$b 语法错误：$(bash -n "$f" 2>&1 | head -2 | tr '\n' ' ')"
  fi
  if [ -x "$f" ]; then
    ok "$b 可执行"
  else
    err "$b 不可执行（chmod +x）"
  fi
done

# ── 4. 都 source 了 common.sh ───────────────────────────────────
echo "--- 4. 公共层依赖 ---"
for f in "${SCRIPTS[@]}"; do
  b="$(basename "$f")"
  case " $TOOLS " in *" $b "*) continue ;; esac   # 工具脚本不进路由表
  if grep -qE 'source .*common\.sh' "$f"; then
    ok "$b source 了 common.sh"
  else
    err "$b 没有 source common.sh —— 绕过了公共层（JSON 契约/日志/黑名单会失效）"
  fi
done

# ── 5. SKILL.md 行数 ≤ 150 ──────────────────────────────────────
echo "--- 5. SKILL.md 篇幅 ---"
LINES=$(wc -l < "$SKILL_MD" | tr -d ' ')
if [ "$LINES" -le 150 ]; then
  ok "SKILL.md $LINES 行（≤150）"
else
  err "SKILL.md $LINES 行，超过 150 行上限 —— 模型每次都要读这么多"
fi

# ── 6. manifest.json ────────────────────────────────────────────
echo "--- 6. manifest.json ---"
if [ ! -f "$MANIFEST" ]; then
  err "manifest.json 缺失"
else
  if python3 -c "import json,sys; json.load(open('$MANIFEST'))" 2>/dev/null; then
    ok "manifest.json 是合法 JSON"
  else
    err "manifest.json 不是合法 JSON"
  fi
  ENTRY=$(python3 -c "
import json
try: print(json.load(open('$MANIFEST')).get('entry',''))
except Exception: print('')
" 2>/dev/null)
  if [ -n "$ENTRY" ] && [ -f "$SKILL_DIR/$ENTRY" ]; then
    ok "entry 指向的文件存在：$ENTRY"
  else
    err "manifest.json 的 entry 无效：$ENTRY"
  fi
fi

# ── 7. 返回契约完整性（所有出口都要 emit）──────────────────────
echo "--- 5'. 失败语义（FR-7：禁止静默失败）---"
for f in "${SCRIPTS[@]}"; do
  b="$(basename "$f")"
  case " $TOOLS " in *" $b "*) continue ;; esac
  if grep -q "emit " "$f"; then
    ok "$b 有 emit 输出"
  else
    err "$b 没有 emit 调用 —— 失败会静默"
  fi
  if grep -q "audit " "$f"; then
    ok "$b 有审计日志"
  else
    err "$b 没有 audit 调用 —— SR-3 要求审计日志 100% 覆盖"
  fi
done

# ── 8. bash 变量边界（3.2 + 全角字符会静默破坏脚本）──────────────
# ⚠ 实测踩过：`"$TO」"` 里 bash 3.2 会把全角 」吞进变量名 → unbound variable。
#  这类问题只在特定字符串出现时才暴露，极难排查，所以放进 lint 静态拦截。
echo "--- 7'. bash 变量边界 ---"
BOUNDARY=$(python3 - "$DIR" <<'PY'
import io, os, re, sys
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]')
bad = []
for f in sorted(os.listdir(sys.argv[1])):
    if not f.endswith('.sh'):
        continue
    p = os.path.join(sys.argv[1], f)
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        if line.lstrip().startswith('#'):
            continue
        for m in pat.finditer(line):
            bad.append("%s:%d" % (f, i))
print(' '.join(bad))
PY
)
if [ -z "$BOUNDARY" ]; then
  ok "无 \$VAR 紧跟全角字符的隐患"
else
  err "\$VAR 后紧跟非 ASCII 字符（bash 3.2 会吞进变量名）：$BOUNDARY"
fi

# ── 9. 大JSON 不得走管道 ──────────────────────────────────────
# 管道传含中文的 10KB JSON 会被截断（实测踩过，表现为「元素存在却找不到」）。
# 排除：① 注释行（common.sh 里有反面示例）② selftest/lint 自身
#     （它们校验的是 emit 的小输出，几百字节，不在风险范围）
echo "--- 8'. 禁止管道传大JSON ---"
PIPEHIT=$(python3 - "$DIR" <<'PY'
import io, os, re, sys
# 两种违规写法：mj...| python3   或   printf '%s' "$VAR" | python3
# ⚠ 关键：这条规则**只针对 JSON**，不是禁所有管道。
#   原实现只匹配 `printf '%s' "$VAR" |` 就判违规 → 误报：
#   route.sh 里 7 行纯文本处理（printf '%s' "$X" | sed 去空格）全被当成 JSON 管道。
#   （2026-10-21 实测踩到，7 处假失败。）
#
#   正确判据是「管道下游是否在消费 JSON」：
#     ① mj/macctl 输出走管道 —— 一定是 JSON
#     ② 任意变量 | python3 —— python3 是解析 JSON 的标准手段
#   而 sed / grep / tr / head 是纯文本工具，不算违规。
pat = re.compile(r"mj[a-z_]*\s+[^|]*\|\s*python3"
                 r"|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\s*\|\s*python3")
# bench.sh 用管道只是 grep 一个布尔子串，不做 JSON 解析，无截断风险
skip = {"selftest.sh", "lint.sh", "common.sh", "bench.sh", "flashctl.sh"}
bad = []
for f in sorted(os.listdir(sys.argv[1])):
    if not f.endswith('.sh') or f in skip:
        continue
    p = os.path.join(sys.argv[1], f)
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        if line.lstrip().startswith('#'):
            continue
        if pat.search(line):
            bad.append("%s:%d" % (f, i))
print(' '.join(bad))
PY
)
if [ -z "$PIPEHIT" ]; then
  ok "无管道式 JSON 解析（业务脚本）"
else
  err "这些行在用管道传 JSON（会截断）：$PIPEHIT"
fi

echo
if [ "$ERRORS" -eq 0 ]; then
  echo "✅ lint 通过：路由表与 scripts/ 完全一致"
  exit 0
else
  echo "❌ lint 失败：$ERRORS 个问题"
  exit 1
fi
