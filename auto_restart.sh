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
MAX_IDLE=900  # 15 минут
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

# Функция безопасной очистки процессов
safe_cleanup() {
    echo "[$(date)] 🧹 Выполняем безопасную очистку процессов..."
    
    # Получаем PID текущего скрипта и его родителя
    CURRENT_PID=$$
    PARENT_PID=$(ps -o ppid= -p $$ | xargs)
    
    echo "[$(date)] 📝 Защищаем процессы: $CURRENT_PID (текущий), $PARENT_PID (родитель)"
    
    # Убиваем hivemind процессы, исключая текущий скрипт
    ps aux | grep hivemind | grep -v grep | while read user pid rest; do
        if [[ "$pid" != "$CURRENT_PID" && "$pid" != "$PARENT_PID" ]]; then
            echo "[$(date)] 🔪 Убиваем hivemind процесс: $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    # Убиваем python swarm процессы, исключая текущий скрипт и его родителя
    ps aux | grep "python.*swarm" | grep -v grep | while read user pid rest; do
        if [[ "$pid" != "$CURRENT_PID" && "$pid" != "$PARENT_PID" ]]; then
            # Дополнительная проверка - не наш ли это скрипт?
            if ! ps -p "$pid" -o cmd --no-headers | grep -q "$(basename $0)"; then
                echo "[$(date)] 🔪 Убиваем python swarm процесс: $pid"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    done
    
    # Убиваем процессы по имени файла (более безопасно)
    pkill -f "run_rl_swarm.sh" 2>/dev/null || true
    pkill -f "swarm_launcher.py" 2>/dev/null || true
    pkill -f "rgym_exp" 2>/dev/null || true
    
    # Очищаем временные файлы
    rm -f /tmp/hivemind_* 2>/dev/null || true
    rm -f /tmp/dht_* 2>/dev/null || true
    
    echo "[$(date)] ✅ Очистка завершена, ждем 3 секунд..."
    sleep 3
}

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
        
        # Выполняем безопасную очистку при зависании
        safe_cleanup
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
      
      # Выполняем безопасную очистку после P2P ошибки
      safe_cleanup
      break
    fi

    # Проверка остальных ключевых ошибок
    for ERR in "${KEYWORDS[@]}"; do
      if grep -q "$ERR" "$TMP_LOG"; then
        echo "[$(date)] ❌ Найдена ошибка '$ERR'. Перезапуск..."
        kill -9 "$PID" 2>/dev/null
        
        # Выполняем безопасную очистку после ошибки
        safe_cleanup
        break 2
      fi
    done
  done

  echo "[$(date)] 🔁 Повтор через 3 секунды..."
  sleep 3
done
