#!/usr/bin/env bash
# 監測每次 voice-input invoke 的記憶體使用
# 用法：
#   ./monitor-invoke.sh           # 跑 60 秒監測
#   ./monitor-invoke.sh 120       # 跑 120 秒
#
# 期間按 Fn 錄音，會看到 ASR + LLM 期間的 RAM 變化

DURATION="${1:-60}"
INTERVAL="${INTERVAL:-1}"

echo "=== Voice-input invoke memory monitor ==="
echo "Duration: ${DURATION}s, sample every ${INTERVAL}s"
echo ""
printf "%-9s  %-10s %-10s %-10s %-10s  %s\n" "TIME" "FREE_GB" "ACTIVE_GB" "SWAP_GB" "MIMO_RSS" "EVENT"
echo "─────────────────────────────────────────────────────────────────"

START=$(date +%s)
LAST_LOG_LINES=0
LAST_VOICE_LOG_LINES=0

while [ $(($(date +%s) - START)) -lt $DURATION ]; do
  TS=$(date "+%H:%M:%S")

  # Memory
  FREE=$(vm_stat | awk '/Pages free/ {gsub("[.]","",$3); printf "%.2f", $3*16/1024/1024}')
  ACTIVE=$(vm_stat | awk '/Pages active/ {gsub("[.]","",$3); printf "%.2f", $3*16/1024/1024}')
  SWAP=$(sysctl -n vm.swapusage | awk '{gsub("M","",$7); printf "%.2f", $7/1024}')

  # mimo Python RSS
  MIMO_PID=$(pgrep -f "uvicorn server:app" | tail -1)
  if [ -n "$MIMO_PID" ]; then
    MIMO_RSS=$(ps -p $MIMO_PID -o rss= 2>/dev/null | awk '{printf "%.2fGB", $1/1024/1024}')
  else
    MIMO_RSS="N/A"
  fi

  # Detect ASR or LLM event
  EVENT=""
  ASR_LINES=$(wc -l < /tmp/mimo-server.log 2>/dev/null || echo 0)
  if [ $ASR_LINES -gt $LAST_LOG_LINES ]; then
    LATEST_ASR=$(grep "Transcribed in" /tmp/mimo-server.log | tail -1 | grep -oE 'Transcribed in [0-9.]+s')
    [ -n "$LATEST_ASR" ] && EVENT="🎤 $LATEST_ASR"
    LAST_LOG_LINES=$ASR_LINES
  fi

  VOICE_LINES=$(wc -l < ~/Library/Logs/VoiceInput.log 2>/dev/null || echo 0)
  if [ $VOICE_LINES -gt $LAST_VOICE_LOG_LINES ]; then
    LATEST_LLM=$(grep "Refined " ~/Library/Logs/VoiceInput.log | tail -1 | grep -oE "Refined \([a-z]+\)")
    [ -n "$LATEST_LLM" ] && EVENT="${EVENT} 🤖 $LATEST_LLM"
    LAST_VOICE_LOG_LINES=$VOICE_LINES
  fi

  printf "%-9s  %-10s %-10s %-10s %-10s  %s\n" "$TS" "$FREE" "$ACTIVE" "$SWAP" "$MIMO_RSS" "$EVENT"

  sleep $INTERVAL
done

echo ""
echo "=== Done ==="
