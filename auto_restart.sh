#!/bin/bash

# 0) Определяем путь до rl-swarm
if [ -d "/root/rl-swarm" ]; then
  RL_DIR="/root/rl-swarm"
elif [ -d "/workspace/rl-swarm" ]; then
  RL_DIR="/workspace/rl-swarm"
else
  echo "❌ Не найден rl-swarm ни в /root, ни в /workspace"
  exit 1
fi

# 1) Подготовка "подменного" rm
FAKEBIN="$RL_DIR/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/rm" << EOF
#!/bin/bash
# Если rm вызывается именно для modal-login/temp-data/*.json — ничего не делаем
if [[ "\$1" == "-r" && "\$2" == "$RL_DIR/modal-login/temp-data/"* ]]; then
  exit 0
else
  # Иначе — настоящий rm
  exec /bin/rm "\$@"
fi
EOF

chmod +x "$FAKEBIN/rm"
# Добавляем в PATH вперед системного
export PATH="$FAKEBIN:$PATH"

SCRIPT="$RL_DIR/run_rl_swarm.sh"
TMP_LOG="/tmp/rlswarm_stdout.log"
MAX_IDLE=600  # 10 минут
RESTART_COUNT=0

KEYWORDS=(
  "BlockingIOError"
  "EOFError"
  "RuntimeError"
  "ConnectionResetError"
  "CUDA out of memory"
  "P2PDaemonError"
  "OSError"
  "error was detected while running rl-swarm"
  "Connection refused"
  "requests.exceptions.ConnectionError"
)

P2P_ERROR_MSG="P2PDaemonError('Daemon failed to start in 15.0 seconds')"

echo "[$(date)] 🏁 Начинаем автоматический перезапуск rl-swarm..."
echo "[$(date)] 💡 Пакеты будут установлены только при первом запуске в виртуальное окружение"

while true; do
  RESTART_COUNT=$((RESTART_COUNT + 1))
  echo "[$(date)] 🚀 Запуск #$RESTART_COUNT Gensyn-ноды (в виртуальном окружении)..."

  rm -f "$TMP_LOG"
  # Теперь внутри run_rl_swarm.sh все команды выполняются в активированном .venv
  ( sleep 1 && printf "n\n\n\n" ) | bash "$SCRIPT" 2>&1 | tee "$TMP_LOG" &
  PID=$!

  while kill -0 "$PID" 2>/dev/null; do
    sleep 5

    # Проверка залипания по логу
    if [ -f "$TMP_LOG" ]; then
      current_mod=$(stat -c %Y "$TMP_LOG")
      now=$(date +%s)
      if (( now - current_mod > MAX_IDLE )); then
        echo "[$(date)] ⚠️ Лог не обновлялся более $((MAX_IDLE/60)) мин. Перезапуск..."
        kill -9 "$PID" 2>/dev/null
        sleep 3
        break
      fi
    fi

    # Если P2PDaemonError — патчим timeout
    if grep -q "$P2P_ERROR_MSG" "$TMP_LOG"; then
      echo "[$(date)] 🛠 P2PDaemonError — патчим startup_timeout..."

      DAEMON_FILE=$(find "$RL_DIR/.venv" -type f -path "*/site-packages/hivemind/p2p/p2p_daemon.py" | head -n1)
      if [[ -n "$DAEMON_FILE" ]]; then
        sed -i -E 's/(startup_timeout: *float *= *)15(,?)/\1120\2/' "$DAEMON_FILE"
        echo "[$(date)] ✏️ timeout patched in $DAEMON_FILE"
      else
        echo "[$(date)] ❌ p2p_daemon.py не найден"
      fi

      kill -9 "$PID" 2>/dev/null
      sleep 3
      break
    fi

    # Проверка остальных ключевых ошибок
    for ERR in "${KEYWORDS[@]}"; do
      if grep -q "$ERR" "$TMP_LOG"; then
        echo "[$(date)] ❌ Найдена ошибка '$ERR'. Перезапуск..."
        kill -9 "$PID" 2>/dev/null
        sleep 3
        break 2
      fi
    done
  done

  echo "[$(date)] 🔁 Повтор через 3 секунды..."
  sleep 3
done
