#!/bin/bash
# 端到端测试：伪造的账号 + 临时目录 + 独立钥匙串服务名，不触碰真实的 ~/.codex 与账号库。
set -uo pipefail
cd "$(dirname "$0")/.."
./build.sh --cli-only >/dev/null

BIN="$PWD/.build/codex-switch"
WORK="$(mktemp -d)"
export CODEX_HOME="$WORK/codex"
export CODEX_SWITCH_HOME="$WORK/data"
export CODEX_SWITCH_KEYCHAIN_SERVICE="codex-switch-test-$$"
export CODEX_SWITCH_APP_BUNDLE_IDS=none
mkdir -p "$CODEX_HOME"

PASS=0
FAIL=0
cleanup() {
  "$BIN" __test-purge >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

check() { # 描述 期望(0/1) 命令...
  local desc="$1" expect="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local code=$?
  if { [ "$expect" = 0 ] && [ $code -eq 0 ]; } || { [ "$expect" = 1 ] && [ $code -ne 0 ]; }; then
    PASS=$((PASS + 1)); echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1)); echo "  ✗ $desc（退出码 $code）"; echo "$out" | sed 's/^/      /'
  fi
  LAST="$out"
}
contains() { # 描述 子串
  if grep -qF -- "$2" <<<"$LAST"; then PASS=$((PASS + 1)); echo "  ✓ $1"
  else FAIL=$((FAIL + 1)); echo "  ✗ $1：输出中没有 “$2”"; echo "$LAST" | sed 's/^/      /'; fi
}
lacks() {
  if grep -qF -- "$2" <<<"$LAST"; then FAIL=$((FAIL + 1)); echo "  ✗ $1：输出中不应出现 “$2”"
  else PASS=$((PASS + 1)); echo "  ✓ $1"; fi
}

# 生成伪造 auth.json：email account_id plan refresh_token last_refresh
fake_auth() {
  python3 -I - "$@" <<'PY'
import base64, json, sys
email, account, plan, refresh, last = sys.argv[1:6]
b64 = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
claims = {"email": email, "sub": "user-" + account,
          "https://api.openai.com/auth": {"chatgpt_account_id": account, "chatgpt_plan_type": plan}}
jwt = b64({"alg": "none"}) + "." + b64(claims) + ".sig"
print(json.dumps({"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "last_refresh": last,
                  "tokens": {"id_token": jwt, "access_token": "AT-" + refresh, "refresh_token": refresh,
                             "account_id": account}}))
PY
}
auth_refresh() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["tokens"]["refresh_token"])' "$CODEX_HOME/auth.json"; }
mode_of() { stat -f %Lp "$1"; }

echo "导入与列表"
fake_auth alice@example.com acct-alice plus RT-ALICE-1 2026-10-01T10:00:00.123456Z > "$CODEX_HOME/auth.json"
chmod 600 "$CODEX_HOME/auth.json"
check "导入当前登录" 0 "$BIN" import --label 工作号
contains "提示已添加" "已添加 #1 工作号"
check "重复导入不重复添加" 0 "$BIN" import
contains "提示已是最新" "已是最新"
check "列表" 0 "$BIN" list
contains "列表标记当前账号" "*  1  工作号"
lacks "列表不泄露令牌" "RT-ALICE"
check "索引文件不含令牌" 1 grep -q "RT-ALICE" "$CODEX_SWITCH_HOME/accounts.json"
[ "$(mode_of "$CODEX_SWITCH_HOME")" = 700 ] && [ "$(mode_of "$CODEX_SWITCH_HOME/accounts.json")" = 600 ] \
  && { PASS=$((PASS + 1)); echo "  ✓ 数据目录 0700 / 索引 0600"; } \
  || { FAIL=$((FAIL + 1)); echo "  ✗ 数据目录或索引权限不对"; }

fake_auth Bob@Example.com acct-bob pro RT-BOB-1 1790000000 > "$WORK/bob.json"
check "从文件导入并删除源文件" 0 "$BIN" import --from "$WORK/bob.json" --delete-source
[ ! -e "$WORK/bob.json" ] && { PASS=$((PASS + 1)); echo "  ✓ 源文件已删除"; } || { FAIL=$((FAIL + 1)); echo "  ✗ 源文件仍存在"; }

echo "切换与令牌回存"
# 模拟 Codex 在使用期间轮换了 alice 的 refresh_token
fake_auth alice@example.com acct-alice plus RT-ALICE-2 2026-10-02T10:00:00Z > "$CODEX_HOME/auth.json"
check "按邮箱（不区分大小写）切换到 bob" 0 "$BIN" switch bob@example.com
contains "提示回存了轮换后的令牌" "刷新后的令牌存回钥匙串"
[ "$(auth_refresh)" = RT-BOB-1 ] && { PASS=$((PASS + 1)); echo "  ✓ auth.json 已是 bob"; } || { FAIL=$((FAIL + 1)); echo "  ✗ auth.json 不是 bob"; }
[ "$(mode_of "$CODEX_HOME/auth.json")" = 600 ] && { PASS=$((PASS + 1)); echo "  ✓ auth.json 权限 0600"; } || { FAIL=$((FAIL + 1)); echo "  ✗ auth.json 权限不对"; }
check "切回 alice" 0 "$BIN" switch 1
[ "$(auth_refresh)" = RT-ALICE-2 ] && { PASS=$((PASS + 1)); echo "  ✓ 切回后使用轮换后的新令牌"; } || { FAIL=$((FAIL + 1)); echo "  ✗ 切回后令牌是旧的：$(auth_refresh)"; }
check "切换到当前账号无操作" 0 "$BIN" switch 1
contains "提示无需切换" "无需切换"

echo "撤销"
check "undo 回到 bob" 0 "$BIN" undo
[ "$(auth_refresh)" = RT-BOB-1 ] && { PASS=$((PASS + 1)); echo "  ✓ undo 恢复了 bob"; } || { FAIL=$((FAIL + 1)); echo "  ✗ undo 后是 $(auth_refresh)"; }
check "再次 undo 切回 alice" 0 "$BIN" undo
[ "$(auth_refresh)" = RT-ALICE-2 ] && { PASS=$((PASS + 1)); echo "  ✓ 再次 undo 回到 alice"; } || { FAIL=$((FAIL + 1)); echo "  ✗ 再次 undo 后是 $(auth_refresh)"; }

echo "未保存的当前登录会被自动保存"
fake_auth carol@example.com acct-carol team RT-CAROL-1 2026-10-03T10:00:00Z > "$CODEX_HOME/auth.json"
check "切走未保存的 carol" 0 "$BIN" switch 2
contains "自动加入账号库" "已自动加入账号库（#3）"

echo "安全防护"
check "未知账号报错" 1 "$BIN" switch nobody
check "非交互删除需要 --yes" 1 "$BIN" remove 3 </dev/null
ln -sf "$WORK/elsewhere.json" "$WORK/link.json"; echo '{}' > "$WORK/elsewhere.json"
check "拒绝从符号链接导入" 1 "$BIN" import --from "$WORK/link.json"
contains "提示符号链接" "符号链接"
mv "$CODEX_HOME/auth.json" "$WORK/real-auth.json"; ln -s "$WORK/real-auth.json" "$CODEX_HOME/auth.json"
check "拒绝覆盖符号链接 auth.json" 1 "$BIN" switch 1
[ -L "$CODEX_HOME/auth.json" ] && { PASS=$((PASS + 1)); echo "  ✓ 符号链接未被改动"; } || { FAIL=$((FAIL + 1)); echo "  ✗ 符号链接被替换"; }
rm "$CODEX_HOME/auth.json"; mv "$WORK/real-auth.json" "$CODEX_HOME/auth.json"
chmod 777 "$CODEX_HOME"
check "~/.codex 全局可写时拒绝写入" 1 "$BIN" switch 1
chmod 700 "$CODEX_HOME"
echo '{"auth_mode":"chatgpt","tokens":{"access_token":"x","id_token":"bad"}}' > "$WORK/broken.json"
check "拒绝缺少 refresh_token 的文件" 1 "$BIN" import --from "$WORK/broken.json"
lacks "错误信息不回显内容" '"access_token":"x"'
# 篡改：让索引里 #1 的身份与钥匙串内容不一致（模拟条目被替换或错配）
cp "$CODEX_SWITCH_HOME/accounts.json" "$WORK/index.bak"
python3 -I - "$CODEX_SWITCH_HOME/accounts.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["accounts"][0]["accountId"] = "acct-mallory"
json.dump(d, open(sys.argv[1], "w"))
PY
check "钥匙串内容与身份不符时拒绝切换" 1 "$BIN" switch 1
contains "提示身份不一致" "身份不一致"
cp "$WORK/index.bak" "$CODEX_SWITCH_HOME/accounts.json"

echo "doctor"
chmod 755 "$CODEX_HOME"; chmod 644 "$CODEX_HOME/auth.json"
touch "$CODEX_HOME/.auth.json.codex-switch-LEFTOVER.tmp"
check "doctor 报告问题" 0 "$BIN" doctor
contains "发现 ~/.codex 权限问题" "权限为 0755"
contains "发现残留临时文件" "残留临时文件"
check "doctor --fix" 0 "$BIN" doctor --fix
[ "$(mode_of "$CODEX_HOME")" = 700 ] && [ "$(mode_of "$CODEX_HOME/auth.json")" = 600 ] \
  && [ ! -e "$CODEX_HOME/.auth.json.codex-switch-LEFTOVER.tmp" ] \
  && { PASS=$((PASS + 1)); echo "  ✓ 权限与残留文件已修复"; } || { FAIL=$((FAIL + 1)); echo "  ✗ doctor --fix 未修复"; }
echo "not json" > "$CODEX_SWITCH_HOME/accounts.json"
check "索引损坏时普通命令报错" 1 "$BIN" list
check "doctor --fix 从钥匙串重建索引" 0 "$BIN" doctor --fix
check "重建后列表" 0 "$BIN" list
contains "重建后找回 carol" "carol@example.com"

echo "删除与重命名"
check "重命名" 0 "$BIN" rename carol@example.com 测试号
check "删除" 0 "$BIN" remove 测试号 --yes
check "删除后列表" 0 "$BIN" list
lacks "列表中不再有测试号" "测试号"

echo "额度解析（不联网）"
cat > "$WORK/usage-both.json" <<'JSON'
{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":22,"limit_window_seconds":18000,"reset_at":1790000000},
 "secondary_window":{"used_percent":41.4,"limit_window_seconds":604800,"reset_at":1790500000}}}
JSON
check "解析 5h 与每周窗口" 0 "$BIN" __test-parse-usage "$WORK/usage-both.json"
contains "剩余百分比与计划正确" "5h=78 week=58 plan=plus"
echo '{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_at":1790500000}}}' > "$WORK/usage-week.json"
check "只有周窗口" 0 "$BIN" __test-parse-usage "$WORK/usage-week.json"
contains "周窗口不会被当成 5h 窗口" "5h=nil week=0 plan=nil"
echo 'not json' > "$WORK/usage-bad.json"
check "拒绝非 JSON 返回" 1 "$BIN" __test-parse-usage "$WORK/usage-bad.json"
check "列表在没有额度数据时提示查询" 0 "$BIN" list
contains "提示运行 usage" "codex-switch usage"

echo
echo "通过 $PASS，失败 $FAIL"
[ $FAIL -eq 0 ]
