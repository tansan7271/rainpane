#!/bin/zsh
# 빌드 → 셰이더 런타임 컴파일 검사(스냅샷 1장) → 통과할 때만 앱 재시작
set -euo pipefail
cd "$(dirname "$0")"
./build.sh | tail -1
out=$(RAINPANE_SNAPSHOT=/tmp/rainpane-check RAINPANE_SNAPSHOT_TIMES=1 build/Rainpane.app/Contents/MacOS/Rainpane 2>&1 || true)
if print -r -- "$out" | grep -q "GPU init failed"; then
  print -r -- "$out" | grep -E "error:" | head -5
  echo "❌ 셰이더 컴파일 실패. 재시작하지 않음"
  exit 1
fi
pkill -x Rainpane 2>/dev/null || true
sleep 0.5
open build/Rainpane.app
echo "✅ 재시작"
