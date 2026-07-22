#!/usr/bin/env bash
set -euo pipefail

# unifi-fw-cache.sh (v5 - Stable Mirror)

# --- Конфигурация по умолчанию ---
UNIFI_FW_DIR="${UNIFI_FW_DIR:-/var/lib/unifi/firmware}"
CATALOG="${CATALOG:-/var/lib/unifi/firmware.json}"
# ВНИМАНИЕ: Прямой URL недоступен (403 Forbidden). Используйте --fetch-catalog-api
CATALOG_URL="${CATALOG_URL:-https://fw-download.ubnt.com/data/firmware.json}"
APP_VERSION="${APP_VERSION:-}"
DEV_FAMILY="${DEV_FAMILY:-}"
VERSION="${VERSION:-}"
UNIFI_USER="${UNIFI_USER:-unifi}"
UNIFI_GROUP="${UNIFI_GROUP:-unifi}"
RESTART="${RESTART:-1}"
REWRITE_HOST="${REWRITE_HOST:-}"
REWRITE_CATALOG_HOST="${REWRITE_CATALOG_HOST:-}"
MIRROR_ROOT="${MIRROR_ROOT:-.}"
DOWNLOAD_THREADS="${DOWNLOAD_THREADS:-5}"
MAX_CATALOG_AGE="${MAX_CATALOG_AGE:-20}"
CATALOG_BACKUP="${CATALOG_BACKUP:-1}"
MAX_BACKUPS="${MAX_BACKUPS:-5}"

SRC_DIR=""
FROM_CATALOG=0
MIRROR_ALL=0
UPDATE_CATALOG=0
AUTO_UPDATE_CATALOG=0
FETCH_CATALOG_API=0
CODES=()
EXTRA_SOURCES=()
SRC_URL_PAIRS=()
LAST_FILE_INDEX=-1
NEED_CONTROLLER=0
FILTER_REGEX=""

# Интеграция с API контроллера (--codes-from-controller)
CODES_FROM_CONTROLLER=0
LIST_CONTROLLER_CODES=0
CODES_FROM_DB=0
API_CREDS_FILE=""
UNIFI_API_URL="${UNIFI_API_URL:-}"    # default https://localhost:8443 подставляется в load_api_creds
UNIFI_API_USER="${UNIFI_API_USER:-}"
UNIFI_API_PASS="${UNIFI_API_PASS:-}"
API_COOKIE_JAR=""
API_CSRF_TOKEN=""
API_BASE=""
API_CURL_ARGS=()

# Кэш каталога для find_compatible_devices
CATALOG_CACHE=""
CATALOG_CACHE_FILE=""
CATALOG_CACHE_VERSION=""

# Временные файлы
TEMP_META_FILE="$(mktemp)"
DOWNLOAD_LIST="$(mktemp)"

cleanup() { rm -f "$TEMP_META_FILE" "$DOWNLOAD_LIST" ${API_COOKIE_JAR:+"$API_COOKIE_JAR"}; }
trap cleanup EXIT

# --- Утилиты ---
ts() { date +%Y%m%d-%H%M%S; }

# Ротация бэкапов: оставляем только последние N файлов
rotate_backups() {
  local base_file="$1"
  local max_keep="${2:-$MAX_BACKUPS}"
  local pattern="${base_file}.bak.*"

  # Получаем список бэкапов, сортируем по времени (новые первые), удаляем старые
  local backups
  backups=$(ls -1t $pattern 2>/dev/null || true)

  local count=0
  while IFS= read -r backup; do
    [[ -z "$backup" ]] && continue
    count=$((count + 1))
    if [[ $count -gt $max_keep ]]; then
      rm -f "$backup"
    fi
  done <<< "$backups"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [URL_or_FILE ...]

🎮 Режим контроллера:
  --from-catalog              Кэшировать прошивки из firmware.json
  --filter "REGEX"            Фильтр устройств (напр. "^(UAP|US)" для AP и Switch)
  --codes "CODES"             Список кодов устройств ("U7PG2 UAP6MP UAL6")
  --catalog PATH              Путь к firmware.json (default: /var/lib/unifi/firmware.json)
  --app-version VERSION       Версия контроллера (default: auto)

🌐 Режим зеркала:
  --mirror-all                Создать полное зеркало прошивок
  --mirror-root PATH          Корневая директория зеркала (default: .)
  --rewrite-host HOST         Заменить хост при скачивании (для прокси/зеркала)

📋 Обновление каталога:
  --update-catalog            Обновить firmware.json и выйти
  --auto-update-catalog       Автообновление каталога при запуске (если устарел)
  --fetch-catalog-api         Получить каталог через API Ubiquiti вместо прямого URL
                              (рекомендуется для --mirror-all, т.к. прямой URL недоступен)
  --catalog-url URL           URL источника каталога (может быть недоступен: 403 Forbidden)
                              (default: https://fw-download.ubnt.com/data/firmware.json)
  --rewrite-catalog-host HOST Заменить хост в URL каталога (напр. fw-mirror.example.com)
  --max-catalog-age DAYS      Максимальный возраст каталога в днях (default: 20)
  --no-catalog-backup         Не создавать резервную копию при обновлении

🔌 Интеграция с контроллером (коды adopted-устройств, multi-site):
  --codes-from-controller     Получить коды adopted-устройств через API и кэшировать
                              прошивки для них (включает --from-catalog; коды
                              объединяются с --codes; --filter применяется)
  --list-controller-codes     Только показать найденные коды и выйти (без root).
                              stdout — итоговый список, разбивка по сайтам — stderr
  --api-url URL               Адрес контроллера (default: https://localhost:8443)
  --api-user USER             Логин локального администратора (2FA не поддерживается —
                              создайте локального админа без 2FA)
  --api-pass PASS             Пароль (видно в ps; лучше env или файл кредов)
  --api-creds-file PATH       Файл KEY=VALUE с UNIFI_API_URL/USER/PASS (chmod 600)
  --codes-from-db             Альтернатива без учётки: локальный MongoDB контроллера
                              (localhost:27117, нужен mongosh/mongo); API-креды
                              при этом игнорируются

🔧 Дополнительные опции:
  --src-dir PATH              Директория с локальными файлами прошивок
  --src-url URL [FILE]        Сопоставить URL с локальным файлом
  --threads N                 Количество параллельных загрузок (default: 5)
  --no-restart                Не перезапускать службу unifi
  --dev-family CODE           Принудительно указать семейство устройства
  --version VERSION           Принудительно указать версию прошивки
  -h, --help                  Показать эту справку

📝 Переменные окружения:
  UNIFI_FW_DIR                Директория кэша (default: /var/lib/unifi/firmware)
  CATALOG                     Путь к firmware.json (default: /var/lib/unifi/firmware.json)
  CATALOG_URL                 URL источника каталога
  APP_VERSION                 Версия контроллера (default: auto)
  UNIFI_USER                  Владелец файлов (default: unifi)
  UNIFI_GROUP                 Группа файлов (default: unifi)
  RESTART                     Перезапускать unifi (1/0, default: 1)
  REWRITE_HOST                Заменить хост при загрузке прошивок
  REWRITE_CATALOG_HOST        Заменить хост в каталоге
  MIRROR_ROOT                 Корень зеркала (default: .)
  DOWNLOAD_THREADS            Количество потоков (default: 5)
  MAX_CATALOG_AGE             Максимальный возраст каталога в днях (default: 20)
  CATALOG_BACKUP              Делать резервные копии (1/0, default: 1)
  UNIFI_API_URL               Адрес контроллера для --codes-from-controller
  UNIFI_API_USER              Логин администратора API
  UNIFI_API_PASS              Пароль администратора API

💡 Примеры использования:

  # Кэшировать прошивки для конкретных устройств
  sudo ./$(basename "$0") --from-catalog --codes "UAP6MP U7PG2 UAL6"

  # Скачать прошивку по прямому URL (автоопределение совместимых устройств)
  sudo ./$(basename "$0") https://dl.ui.com/unifi/firmware/U7PG2/6.7.35.15586/file.bin

  # Несколько прошивок за раз
  sudo ./$(basename "$0") url1.bin url2.bin url3.bin --threads 10

  # Обновить firmware.json с переписыванием хостов
  sudo ./$(basename "$0") --update-catalog \\
    --catalog-url https://fw-mirror.example.com/firmware.json \\
    --rewrite-catalog-host fw-mirror.example.com

  # Автообновление каталога при скачивании прошивок
  sudo ./$(basename "$0") --auto-update-catalog --from-catalog --codes "U7PG2"

  # Создать зеркало через API Ubiquiti (рекомендуется)
  ./$(basename "$0") --fetch-catalog-api \\
    --rewrite-catalog-host fw-mirror.example.com \\
    --mirror-all --mirror-root /srv/unifi-mirror

  # Создать зеркало с кастомного зеркала (если есть свой mirror с firmware.json)
  ./$(basename "$0") --update-catalog \\
    --catalog-url https://your-internal-mirror.local/firmware.json \\
    --rewrite-catalog-host your-internal-mirror.local \\
    --mirror-all --mirror-root /srv/unifi-mirror

  # Добавить локальные файлы в кэш
  sudo ./$(basename "$0") --src-dir /path/to/firmware-files/

  # Использовать внутреннее зеркало
  REWRITE_HOST=mirror.local sudo -E ./$(basename "$0") --from-catalog --codes "UAP6MP"

📚 Документация:
  README.md           - Основная документация
  CATALOG_UPDATE.md   - Руководство по обновлению каталога

🔗 Подробнее: https://github.com/nimbo78/unifi-fw-cache
EOF
}

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-catalog) FROM_CATALOG=1; shift ;;
    --codes) shift; IFS=' ' read -r -a CODES <<< "${1:-}" || true; shift || true ;;
    --filter) shift; FILTER_REGEX="${1:-}"; shift || true ;;
    --app-version) shift; APP_VERSION="${1:-$APP_VERSION}"; shift || true ;;
    --catalog) shift; CATALOG="${1:-$CATALOG}"; shift || true ;;
    --src-dir) shift; SRC_DIR="${1:-}"; shift || true ;;
    --src-url)
      shift; src_url="${1:-}"; [[ -z "$src_url" ]] && exit 2
      shift || true
      if [[ $# -gt 0 && ! "$1" =~ ^- && ! "$1" =~ ^https?:// ]]; then
        SRC_URL_PAIRS+=("$src_url|$1"); shift || true
      elif [[ $LAST_FILE_INDEX -ge 0 ]]; then
        src_file="${EXTRA_SOURCES[$LAST_FILE_INDEX]}"
        SRC_URL_PAIRS+=("$src_url|$src_file")
        unset "EXTRA_SOURCES[$LAST_FILE_INDEX]"
        LAST_FILE_INDEX=-1
      else
        echo "Error: --src-url без файла" >&2; exit 2
      fi
      ;;
    --mirror-all) MIRROR_ALL=1; shift ;;
    --mirror-root) shift; MIRROR_ROOT="${1:-$MIRROR_ROOT}"; shift || true ;;
    --rewrite-host) shift; REWRITE_HOST="${1:-}"; shift || true ;;
    --rewrite-catalog-host) shift; REWRITE_CATALOG_HOST="${1:-}"; shift || true ;;
    --dev-family) shift; DEV_FAMILY="${1:-}"; shift || true ;;
    --version) shift; VERSION="${1:-}"; shift || true ;;
    --threads) shift; DOWNLOAD_THREADS="${1:-5}"; shift || true ;;
    --no-restart) RESTART=0; shift ;;
    --update-catalog) UPDATE_CATALOG=1; shift ;;
    --auto-update-catalog) AUTO_UPDATE_CATALOG=1; shift ;;
    --fetch-catalog-api) FETCH_CATALOG_API=1; shift ;;
    --codes-from-controller) CODES_FROM_CONTROLLER=1; shift ;;
    --list-controller-codes) LIST_CONTROLLER_CODES=1; shift ;;
    --codes-from-db) CODES_FROM_DB=1; CODES_FROM_CONTROLLER=1; shift ;;
    --api-url) shift; UNIFI_API_URL="${1:-}"; shift || true ;;
    --api-user) shift; UNIFI_API_USER="${1:-}"; shift || true ;;
    --api-pass) shift; UNIFI_API_PASS="${1:-}"; shift || true ;;
    --api-creds-file) shift; API_CREDS_FILE="${1:-}"; shift || true ;;
    --catalog-url) shift; CATALOG_URL="${1:-$CATALOG_URL}"; shift || true ;;
    --max-catalog-age) shift; MAX_CATALOG_AGE="${1:-20}"; shift || true ;;
    --no-catalog-backup) CATALOG_BACKUP=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown: $1" >&2; usage; exit 2 ;;
    *)
      if [[ "$1" =~ ^https?:// ]]; then EXTRA_SOURCES+=("$1"); LAST_FILE_INDEX=-1
      else EXTRA_SOURCES+=("$1"); LAST_FILE_INDEX=$((${#EXTRA_SOURCES[@]}-1)); fi
      shift ;;
  esac
done
while [[ $# -gt 0 ]]; do
  EXTRA_SOURCES+=("$1")
  shift
done

for cmd in jq wget md5sum stat install xargs; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Требуется: $cmd" >&2; exit 1; }
done

# Валидация числовых параметров
if ! [[ "$DOWNLOAD_THREADS" =~ ^[0-9]+$ ]] || [[ "$DOWNLOAD_THREADS" -lt 1 ]]; then
  echo "Ошибка: --threads должен быть положительным числом (получено: '$DOWNLOAD_THREADS')" >&2
  exit 2
fi
if ! [[ "$MAX_CATALOG_AGE" =~ ^[0-9]+$ ]]; then
  echo "Ошибка: --max-catalog-age должен быть числом (получено: '$MAX_CATALOG_AGE')" >&2
  exit 2
fi
if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || [[ "$MAX_BACKUPS" -lt 1 ]]; then
  echo "Ошибка: MAX_BACKUPS должен быть положительным числом (получено: '$MAX_BACKUPS')" >&2
  exit 2
fi

# --- Функции ---

rewrite_url() { [[ -n "$REWRITE_HOST" ]] && echo "$1" | sed -E "s#^(https?://)[^/]+#\1$REWRITE_HOST#" || echo "$1"; }

ensure_dir() {
  local dir="$1"
  if [[ $NEED_CONTROLLER -eq 1 ]]; then install -d -o "$UNIFI_USER" -g "$UNIFI_GROUP" -m 0755 "$dir"
  else mkdir -p "$dir"; fi
}

install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  ensure_dir "$(dirname "$dst")"
  if [[ $NEED_CONTROLLER -eq 1 ]]; then install -o "$UNIFI_USER" -g "$UNIFI_GROUP" -m "$mode" "$src" "$dst"
  else cp "$src" "$dst" && chmod "$mode" "$dst"; fi
}

check_catalog_age() {
  local catalog="$1"
  local max_age="${2:-20}"

  [[ ! -f "$catalog" ]] && return 1

  local file_age_days=$(( ($(date +%s) - $(stat -c%Y "$catalog")) / 86400 ))

  if [[ $file_age_days -gt $max_age ]]; then
    echo "⚠️ Каталог устарел: $file_age_days дней (лимит: $max_age дней)"
    return 1
  fi

  echo "✅ Каталог актуален: $file_age_days дней"
  return 0
}

normalize_host() {
  local host="$1"

  # Убрать trailing slash если есть
  host="${host%/}"

  # Если уже есть протокол, вернуть как есть
  if [[ "$host" =~ ^https?:// ]]; then
    echo "$host"
    return
  fi

  # Иначе добавить https://
  echo "https://$host"
}

rewrite_catalog_hosts() {
  local catalog="$1"
  local new_host="$2"

  # Нормализовать хост (добавить https:// если нужно)
  new_host=$(normalize_host "$new_host")

  local tmp_catalog; tmp_catalog="$(mktemp)"
  # Очистка временного файла при выходе из функции
  trap 'rm -f "$tmp_catalog" 2>/dev/null' RETURN

  echo "🔄 Переписывание хостов на: $new_host"

  # Заменить хост во всех URL, сохраняя весь путь
  jq --arg host "$new_host" '
    walk(
      if type == "object" and has("url") then
        .url |= sub("^https?://[^/]+"; $host)
      else . end
    )
  ' "$catalog" > "$tmp_catalog" 2>/dev/null

  # Проверить валидность и размер
  if [[ ! -s "$tmp_catalog" ]]; then
    echo "⚠️ walk() не сработала, используем альтернативный метод..." >&2
    # Альтернативный метод: используем sed для замены любого хоста в URL
    # Паттерн: https://любой-хост/ -> $new_host/
    sed -E 's|"url"[[:space:]]*:[[:space:]]*"https?://[^/]+/|"url": "'"$new_host"'/|g' "$catalog" > "$tmp_catalog"

    if [[ ! -s "$tmp_catalog" ]] || ! jq empty "$tmp_catalog" 2>/dev/null; then
      echo "❌ Ошибка при переписывании хостов" >&2
      return 1
    fi
  fi

  if jq empty "$tmp_catalog" 2>/dev/null; then
    mv "$tmp_catalog" "$catalog"
    echo "✅ Хосты переписаны"
    return 0
  else
    echo "❌ Ошибка при переписывании хостов: невалидный JSON" >&2
    return 1  # trap RETURN удалит tmp_catalog
  fi
}

update_catalog() {
  local source_url="${1:-$CATALOG_URL}"
  local target_file="${2:-$CATALOG}"
  local rewrite_host="${3:-$REWRITE_CATALOG_HOST}"
  local backup="${4:-$CATALOG_BACKUP}"

  echo "📥 Обновление каталога из: $source_url"

  # Резервная копия
  if [[ $backup -eq 1 && -f "$target_file" ]]; then
    local backup_file="${target_file}.bak.$(ts)"
    cp "$target_file" "$backup_file" 2>/dev/null || true
    echo "💾 Резервная копия: $backup_file"
    rotate_backups "$target_file"
  fi

  # Скачать новый каталог
  local tmp_file; tmp_file="$(mktemp)"
  if ! wget -q -O "$tmp_file" "$source_url" 2>/dev/null; then
    echo "❌ Ошибка загрузки каталога, используется старый"
    rm -f "$tmp_file"
    return 1
  fi

  # Проверить валидность JSON
  if ! jq empty "$tmp_file" 2>/dev/null; then
    echo "❌ Невалидный JSON, используется старый каталог"
    rm -f "$tmp_file"
    return 1
  fi

  # Переписать хосты, если нужно
  if [[ -n "$rewrite_host" ]]; then
    if ! rewrite_catalog_hosts "$tmp_file" "$rewrite_host"; then
      rm -f "$tmp_file"
      return 1
    fi
  fi

  # Заменить старый каталог
  ensure_dir "$(dirname "$target_file")"
  if [[ $NEED_CONTROLLER -eq 1 || $UPDATE_CATALOG -eq 1 ]]; then
    # Для режима контроллера или явного обновления - правильные права
    if is_root; then
      install -o "$UNIFI_USER" -g "$UNIFI_GROUP" -m 0644 "$tmp_file" "$target_file" 2>/dev/null || cp "$tmp_file" "$target_file"
    else
      cp "$tmp_file" "$target_file"
    fi
  else
    cp "$tmp_file" "$target_file"
  fi
  rm -f "$tmp_file"

  echo "✅ Каталог обновлён: $target_file"
  return 0
}

fetch_and_convert_firmware_api() {
  local target_file="${1:-firmware.json}"
  local rewrite_host="${2:-}"

  local api_url="https://fw-update.ubnt.com/api/firmware-latest"
  local filters="filter=eq~~product~~unifi-firmware&filter=eq~~channel~~release&limit=5000"

  echo "📡 Загрузка каталога через API Ubiquiti..."
  echo "   Источник: $api_url?$filters"

  # Скачать JSON с API
  local tmp_api; tmp_api="$(mktemp)"
  if ! wget -q -O "$tmp_api" "$api_url?$filters" 2>/dev/null; then
    echo "❌ Ошибка загрузки API" >&2
    rm -f "$tmp_api"
    return 1
  fi

  # Проверить валидность JSON
  if ! jq empty "$tmp_api" 2>/dev/null; then
    echo "❌ Невалидный JSON от API" >&2
    rm -f "$tmp_api"
    return 1
  fi

  # Преобразовать формат API в формат firmware.json
  local tmp_catalog; tmp_catalog="$(mktemp)"
  echo "🔄 Преобразование формата API в firmware.json..."

  # Извлечь количество устройств
  local count; count=$(jq '._embedded.firmware | length' "$tmp_api" 2>/dev/null || echo 0)
  echo "   Найдено устройств: $count"

  # Преобразовать: создаём структуру {"mirror": {"release": {...}}}
  jq '
    {
      "mirror": {
        "release": (
          ._embedded.firmware |
          map({
            (.platform): {
              url: ._links.data.href,
              md5sum: .md5,
              version: .version,
              size: .file_size
            }
          }) |
          add
        )
      }
    }
  ' "$tmp_api" > "$tmp_catalog" 2>/dev/null

  if ! jq empty "$tmp_catalog" 2>/dev/null; then
    echo "❌ Ошибка преобразования формата" >&2
    rm -f "$tmp_api" "$tmp_catalog"
    return 1
  fi

  rm -f "$tmp_api"

  # Определить путь к файлу с оригинальными ссылками
  local target_dir; target_dir="$(dirname "$target_file")"
  local ubnt_catalog="$target_dir/firmware.ubnt.json"

  # Сохранить каталог с оригинальными ссылками Ubiquiti
  ensure_dir "$target_dir"
  cp "$tmp_catalog" "$ubnt_catalog"
  echo "💾 Каталог с оригинальными ссылками: $ubnt_catalog"

  # Если нужно переписать хосты - создаём отдельный файл
  if [[ -n "$rewrite_host" ]]; then
    if ! rewrite_catalog_hosts "$tmp_catalog" "$rewrite_host"; then
      rm -f "$tmp_catalog"
      return 1
    fi
    cp "$tmp_catalog" "$target_file"
    echo "✅ Каталог с переписанными хостами: $target_file"
    echo "   Для скачивания используйте: $ubnt_catalog"
  else
    # Без переписывания - просто копируем
    cp "$tmp_catalog" "$target_file"
    echo "✅ Каталог создан: $target_file"
  fi

  rm -f "$tmp_catalog"

  echo "   Версия для APP_VERSION: mirror"
  return 0
}

# Загрузка кэша каталога (вызывается один раз)
load_catalog_cache() {
  local catalog="$1"
  local app_version="$2"

  # Проверяем, нужно ли обновить кэш
  if [[ "$CATALOG_CACHE_FILE" == "$catalog" && "$CATALOG_CACHE_VERSION" == "$app_version" && -n "$CATALOG_CACHE" ]]; then
    return 0
  fi

  [[ ! -f "$catalog" ]] && return 1

  # Извлекаем все записи один раз: key|md5sum|version|url
  CATALOG_CACHE=$(jq -r --arg v "$app_version" '
    .[$v].release | to_entries[] |
    "\(.key)|\(.value.md5sum // "")|\(.value.version // "")|\(.value.url // "")"
  ' "$catalog" 2>/dev/null || true)

  CATALOG_CACHE_FILE="$catalog"
  CATALOG_CACHE_VERSION="$app_version"
}

find_compatible_devices() {
  local url="$1" md5="${2:-}" ver="${3:-}"
  local catalog="${CATALOG:-/var/lib/unifi/firmware.json}"
  local app_version="${APP_VERSION:-}"

  # Если каталог недоступен, возвращаем пустую строку (будет использован fallback)
  [[ ! -f "$catalog" ]] && return 0

  # Автоопределение версии приложения
  if [[ -z "$app_version" || "$app_version" == "auto" ]]; then
    app_version=$(jq -r 'keys[]' "$catalog" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -n1 || true)
  fi
  [[ -z "$app_version" ]] && return 0

  # Загружаем кэш каталога (один раз для файла+версии)
  load_catalog_cache "$catalog" "$app_version"
  [[ -z "$CATALOG_CACHE" ]] && return 0

  local devices=""
  local filename=""
  [[ -n "$url" ]] && filename="$(basename "$url")"

  # Приоритет 1: Поиск по MD5 (самый надёжный)
  if [[ -n "$md5" ]]; then
    while IFS='|' read -r dev_key dev_md5 dev_ver dev_url; do
      [[ -z "$dev_key" ]] && continue
      [[ "$dev_md5" == "$md5" ]] && devices+="$dev_key "
    done <<< "$CATALOG_CACHE"
  fi

  # Приоритет 2: Поиск по имени файла и версии (если MD5 ничего не нашёл)
  if [[ -z "$devices" && -n "$filename" && -n "$ver" ]]; then
    while IFS='|' read -r dev_key dev_md5 dev_ver dev_url; do
      [[ -z "$dev_key" ]] && continue
      [[ "$dev_url" == *"$filename" && "$dev_ver" == "$ver" ]] && devices+="$dev_key "
    done <<< "$CATALOG_CACHE"
  fi

  # Приоритет 3: Поиск только по имени файла (если ничего не найдено)
  if [[ -z "$devices" && -n "$filename" ]]; then
    while IFS='|' read -r dev_key dev_md5 dev_ver dev_url; do
      [[ -z "$dev_key" ]] && continue
      [[ "$dev_url" == *"$filename" ]] && devices+="$dev_key "
    done <<< "$CATALOG_CACHE"
  fi

  # Убираем дубликаты и trailing space
  echo "$devices" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

add_meta_buffer() {
  [[ $NEED_CONTROLLER -eq 1 ]] || return 0
  local rel="$1" ver="$2" codes="$3" file="$4"
  if [[ -f "$file" ]]; then
    local md5 size
    md5="$(md5sum "$file" | awk '{print $1}')"
    size="$(stat -c%s "$file")"

    # Преобразуем строку кодов (через пробел) в JSON массив
    local devices_json
    if [[ "$codes" == *" "* ]]; then
      # Несколько кодов - создаём массив
      devices_json=$(printf '%s\n' $codes | jq -R . | jq -s .)
    else
      # Один код - тоже массив
      devices_json=$(jq -n -c --arg code "$codes" '[$code]')
    fi

    jq -n -c --arg md5 "$md5" --arg ver "$ver" --argjson size "$size" --arg path "$rel" --argjson devices "$devices_json" \
          '{md5:$md5, version:$ver, size:$size, path:$path, devices:$devices}' >> "$TEMP_META_FILE"
  fi
}

commit_meta() {
  [[ $NEED_CONTROLLER -eq 1 ]] || return 0
  [[ -s "$TEMP_META_FILE" ]] || return 0
  ensure_dir "$UNIFI_FW_DIR"
  local META="$UNIFI_FW_DIR/firmware_meta.json"
  [[ ! -f "$META" ]] && echo '{"cached_firmwares":[]}' > "$META"
  install_file "$META" "${META}.bak.$(ts)" 0644
  rotate_backups "$META"
  echo "Обновление firmware_meta.json..."
  local tmp_json; tmp_json="$(mktemp)"
  jq -s '.[0] as $current | .[1] as $new | ($current.cached_firmwares + $new) | group_by(.path) | map(last) | {cached_firmwares: .}' \
    "$META" <(jq -s '.' "$TEMP_META_FILE") > "$tmp_json"
  install_file "$tmp_json" "$META" 0644
  rm -f "$tmp_json"
}

queue_download() { printf "%s\t%s\n" "$(rewrite_url "$1")" "$2" >> "$DOWNLOAD_LIST"; }

process_download_queue() {
  [[ -s "$DOWNLOAD_LIST" ]] || return 0
  local count; count=$(wc -l < "$DOWNLOAD_LIST")
  echo "Загрузка $count файлов в $DOWNLOAD_THREADS потоков..."
  export -f download_worker
  xargs -a "$DOWNLOAD_LIST" -P "$DOWNLOAD_THREADS" -I {} bash -c 'download_worker "$@"' _ "{}"
  truncate -s 0 "$DOWNLOAD_LIST"
}

download_worker() {
  local line="$1"
  local url="${line%%$'\t'*}"
  local dst="${line#*$'\t'}"
  [[ -z "$url" || -z "$dst" ]] && return 0

  local tmp_dst="${dst}.tmp.$$"

  # Очистка tmp файла при прерывании
  trap 'rm -f "$tmp_dst"' EXIT INT TERM

  mkdir -p "$(dirname "$dst")"
  echo "Download: .../$(basename "$dst")"
  if wget -q -O "$tmp_dst" --tries=3 --timeout=30 "$url"; then
    mv -f "$tmp_dst" "$dst"
  else
    echo "FAIL: $url" >&2
    exit 1  # trap EXIT удалит tmp_dst
  fi
}
export -f download_worker

infer_family_version() {
  local src="$1" fname_base url_path family="" ver=""
  fname_base="$(basename "$src")"
  if [[ "$src" =~ ^https?:// ]]; then
    url_path="${src#*://*/}"
    [[ "$url_path" =~ firmware/([^/]+)/([^/]+)/ ]] && { family="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"; }
  fi
  if [[ -z "$family" ]]; then
    # Access Points (UAP)
    [[ "$fname_base" =~ [-_](UAP6MP|UAP6LR|UAP6PRO|UAP6MESH|UAP6IW)[-_] ]] && family="${BASH_REMATCH[1]}"
    [[ -z "$family" && "$fname_base" =~ [-_](UAPL6|UAL6|U6LR|U6PRO|U6MESH|U6IW|U6LITE)[-_] ]] && family="${BASH_REMATCH[1]}"
    [[ -z "$family" && "$fname_base" =~ [-_](U7PG2|U7MSH|U7LR|U7PRO|U7HD|U7NHD|U7LT)[-_] ]] && family="${BASH_REMATCH[1]}"
    # Switches (USW)
    [[ -z "$family" && "$fname_base" =~ [-_](USW|USWPRO|USW24|USW48|USWFLEX|USWMINI)[-_] ]] && family="${BASH_REMATCH[1]}"
    [[ -z "$family" && "$fname_base" =~ [-_](US8|US16|US24|US48|USXG)[-_] ]] && family="${BASH_REMATCH[1]}"
    # Gateways (UGW/UDM)
    [[ -z "$family" && "$fname_base" =~ [-_](UGW3|UGW4|UGWXG|UDM|UDMPRO|UDMSE|UDR|UXG)[-_] ]] && family="${BASH_REMATCH[1]}"
    # Other devices
    [[ -z "$family" && "$fname_base" =~ [-_](UCK|UCKP|UCKGEN2|UNVR|UNVRPRO)[-_] ]] && family="${BASH_REMATCH[1]}"
    # Fallback: попытка извлечь код устройства из начала имени файла
    [[ -z "$family" && "$fname_base" =~ ^([A-Z][A-Z0-9]+)\. ]] && family="${BASH_REMATCH[1]}"
  fi
  [[ -z "$ver" && "$fname_base" =~ ([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?) ]] && ver="${BASH_REMATCH[1]}"
  echo "${DEV_FAMILY:-$family}|${VERSION:-$ver}"
}

auto_detect_app_version() {
  [[ -n "$APP_VERSION" && "$APP_VERSION" != "auto" ]] && return 0
  [[ -r "$CATALOG" ]] || { echo "Нет доступа к $CATALOG" >&2; exit 1; }
  APP_VERSION="$(jq -r 'keys[]' "$CATALOG" | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -n1 || true)"
  [[ -z "$APP_VERSION" ]] && { echo "Ошибка автоопределения версии" >&2; exit 1; }
  echo "APP_VERSION: $APP_VERSION"
}

get_filtered_codes() {
  local filter_re=".*"
  [[ -n "$FILTER_REGEX" ]] && filter_re="$FILTER_REGEX"
  jq -r --arg v "$APP_VERSION" --arg re "$filter_re" \
       '.[$v].release | keys[] | select(test($re))' "$CATALOG" | tr '\n' ' '
}

# --- Controller API (получение кодов adopted-устройств) ---

# Свести учётные данные API: флаги > env > файл кредов
load_api_creds() {
  if [[ -n "$API_CREDS_FILE" ]]; then
    [[ -r "$API_CREDS_FILE" ]] || { echo "❌ Файл кредов недоступен: $API_CREDS_FILE" >&2; return 1; }
    local perms; perms=$(stat -c '%a' "$API_CREDS_FILE" 2>/dev/null || echo "")
    if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
      echo "⚠️ Файл кредов $API_CREDS_FILE имеет права $perms (рекомендуется 600)" >&2
    fi
    local key val
    # `|| [[ -n "$key" ]]` — не потерять последнюю строку файла без завершающего \n
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
      key="${key//[[:space:]]/}"
      [[ -z "$key" || "$key" == \#* ]] && continue
      val="${val%$'\r'}"  # CRLF из файлов, созданных на Windows
      # Снять только ПАРНЫЕ обрамляющие кавычки
      if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then val="${val:1:${#val}-2}"
      elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
      case "$key" in
        UNIFI_API_URL)  [[ -z "$UNIFI_API_URL"  ]] && UNIFI_API_URL="$val" ;;
        UNIFI_API_USER) [[ -z "$UNIFI_API_USER" ]] && UNIFI_API_USER="$val" ;;
        UNIFI_API_PASS) [[ -z "$UNIFI_API_PASS" ]] && UNIFI_API_PASS="$val" ;;
      esac
    done < "$API_CREDS_FILE"
  fi
  UNIFI_API_URL="${UNIFI_API_URL:-https://localhost:8443}"
  UNIFI_API_URL="$(normalize_host "$UNIFI_API_URL")"
  return 0
}

# Вход в API: сначала self-hosted (/api/login), затем UniFi OS (/api/auth/login)
controller_login() {
  command -v curl >/dev/null 2>&1 || { echo "❌ Для работы с API контроллера требуется curl" >&2; return 1; }
  if [[ -z "$UNIFI_API_USER" || -z "$UNIFI_API_PASS" ]]; then
    echo "❌ Не заданы учётные данные API (--api-user/--api-pass, env UNIFI_API_USER/UNIFI_API_PASS или --api-creds-file)" >&2
    return 1
  fi

  API_COOKIE_JAR="$(mktemp)"
  # Хост без схемы/порта/пути — для --noproxy (прокси не должен перехватывать API)
  local noproxy_host="${UNIFI_API_URL#*://}"
  if [[ "$noproxy_host" == \[* ]]; then
    noproxy_host="${noproxy_host%%\]*}]"  # IPv6 в квадратных скобках
  else
    noproxy_host="${noproxy_host%%[:/]*}"
  fi
  API_CURL_ARGS=(-k -s --noproxy "$noproxy_host" --connect-timeout 10 --max-time 60 -c "$API_COOKIE_JAR" -b "$API_COOKIE_JAR")

  # Пароль передаётся jq через окружение — не попадает в argv (не виден в ps)
  local payload
  payload=$(UNIFI_API_USER="$UNIFI_API_USER" UNIFI_API_PASS="$UNIFI_API_PASS" \
    jq -n '{username: env.UNIFI_API_USER, password: env.UNIFI_API_PASS}')

  local body headers
  body="$(mktemp)"; headers="$(mktemp)"
  # Темпфайлы удаляются явно перед каждым return

  # 1) self-hosted: успех = HTTP 200 И meta.rc == "ok" (не доверять голому 200)
  local code_self code_uos
  code_self=$(printf '%s' "$payload" | curl "${API_CURL_ARGS[@]}" -o "$body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -d @- "$UNIFI_API_URL/api/login" || true)
  code_self="${code_self:-000}"
  if [[ "$code_self" == "200" ]] && jq -e '.meta.rc == "ok"' "$body" >/dev/null 2>&1; then
    API_BASE="$UNIFI_API_URL"
    echo "🔐 Вход выполнен (self-hosted API): $UNIFI_API_URL" >&2
    rm -f "$body" "$headers"
    return 0
  fi
  if [[ "$code_self" == "400" ]]; then
    if grep -q 'Ubic2faTokenRequired' "$body" 2>/dev/null; then
      echo "❌ У аккаунта включена 2FA — создайте локального администратора без 2FA" >&2
    else
      echo "❌ Контроллер отверг учётные данные (HTTP 400): проверьте логин/пароль" >&2
    fi
    rm -f "$body" "$headers"
    return 1
  fi

  # 2) UniFi OS: /api/auth/login + CSRF-токен из заголовка ответа
  code_uos=$(printf '%s' "$payload" | curl "${API_CURL_ARGS[@]}" -D "$headers" -o "$body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -d @- "$UNIFI_API_URL/api/auth/login" || true)
  code_uos="${code_uos:-000}"
  API_CSRF_TOKEN=$(awk -F': ' 'tolower($1)=="x-csrf-token"{gsub(/\r/,"",$2); print $2}' "$headers" | tail -n1)
  if [[ "$code_uos" == "200" ]]; then
    API_BASE="$UNIFI_API_URL/proxy/network"
    echo "🔐 Вход выполнен (UniFi OS API): $UNIFI_API_URL" >&2
    rm -f "$body" "$headers"
    return 0
  fi
  if [[ "$code_uos" == "499" ]]; then
    echo "❌ У аккаунта включена 2FA (HTTP 499) — создайте локального администратора без 2FA" >&2
    rm -f "$body" "$headers"
    return 1
  fi

  echo "❌ Не удалось войти в API ($UNIFI_API_URL): self-hosted HTTP $code_self, UniFi OS HTTP $code_uos" >&2
  rm -f "$body" "$headers"
  return 1
}

# GET-запрос к API с cookie (+CSRF для UniFi OS); тело ответа в stdout
controller_api_get() {
  local path="$1"
  local -a hdr=()
  [[ -n "$API_CSRF_TOKEN" ]] && hdr=(-H "X-Csrf-Token: $API_CSRF_TOKEN")
  curl "${API_CURL_ARGS[@]}" ${hdr[@]+"${hdr[@]}"} "$API_BASE$path"
}

# Best-effort закрытие сессии (сессии не копятся при cron-запусках)
controller_logout() {
  [[ -z "$API_BASE" ]] && return 0
  local -a hdr=()
  [[ -n "$API_CSRF_TOKEN" ]] && hdr=(-H "X-Csrf-Token: $API_CSRF_TOKEN")
  if [[ "$API_BASE" == *"/proxy/network" ]]; then
    curl "${API_CURL_ARGS[@]}" ${hdr[@]+"${hdr[@]}"} -X POST -o /dev/null "$UNIFI_API_URL/api/auth/logout" 2>/dev/null || true
  else
    curl "${API_CURL_ARGS[@]}" ${hdr[@]+"${hdr[@]}"} -X POST -o /dev/null "$UNIFI_API_URL/api/logout" 2>/dev/null || true
  fi
  return 0
}

process_from_catalog() {
  [[ -r "$CATALOG" ]] || { echo "Каталог не найден" >&2; exit 1; }
  
  local target_codes=()
  if [[ ${#CODES[@]} -eq 0 ]]; then
    echo "Поиск устройств для кэша контроллера (filter: '${FILTER_REGEX:-ALL}')..."
    read -r -a target_codes <<< "$(get_filtered_codes)"
    [[ ${#target_codes[@]} -eq 0 ]] && { echo "Устройства не найдены." >&2; return 1; }
  else
    target_codes=("${CODES[@]}")
  fi
  
  echo "Найдено устройств для кэша: ${#target_codes[@]}"

  local json_codes; json_codes=$(printf '%s\n' "${target_codes[@]}" | jq -R . | jq -s .)
  local tasks; tasks=$(jq -r --arg v "$APP_VERSION" --argjson target_codes "$json_codes" '
    .[$v].release | to_entries[] | select(.key as $k | $target_codes | index($k)) 
    | [.key, .value.version, .value.url, .value.md5sum] | @tsv' "$CATALOG")

  [[ -z "$tasks" ]] && { echo "Нет прошивок для загрузки."; return; }

  while IFS=$'\t' read -r code ver url md5sum; do
    local fname target_file rel_path need_download=1
    fname="$(basename "$url")"; target_file="$UNIFI_FW_DIR/$code/$ver/$fname"; rel_path="$code/$ver/$fname"
    if [[ -f "$target_file" ]]; then
      if [[ "$(md5sum "$target_file" | awk '{print $1}')" == "$md5sum" ]]; then
        need_download=0
      fi
    fi
    [[ $need_download -eq 1 ]] && queue_download "$url" "$target_file"
  done <<< "$tasks"

  process_download_queue

  # Добавляем метаданные для всех файлов (существовавших + скачанных)
  while IFS=$'\t' read -r code ver url md5sum; do
    local fname target_file rel_path
    fname="$(basename "$url")"; target_file="$UNIFI_FW_DIR/$code/$ver/$fname"; rel_path="$code/$ver/$fname"
    if [[ -f "$target_file" ]]; then
       [[ "$(md5sum "$target_file" | awk '{print $1}')" == "$md5sum" ]] && add_meta_buffer "$rel_path" "$ver" "$code" "$target_file"
    fi
  done <<< "$tasks"
}

mirror_all() {
  local root="$MIRROR_ROOT"
  local mirror_catalog="$root/firmware.json"

  # Если нужно обновить/получить каталог
  if [[ $UPDATE_CATALOG -eq 1 || $FETCH_CATALOG_API -eq 1 ]]; then
    if [[ $FETCH_CATALOG_API -eq 1 ]]; then
      echo "📦 Получение каталога через API Ubiquiti..."
      if ! fetch_and_convert_firmware_api "$mirror_catalog" "$REWRITE_CATALOG_HOST"; then
        echo "❌ Не удалось получить каталог через API" >&2
        exit 1
      fi
      APP_VERSION="mirror"
    else
      echo "📦 Обновление каталога для зеркала..."
      update_catalog "$CATALOG_URL" "$mirror_catalog" "$REWRITE_CATALOG_HOST" "$CATALOG_BACKUP"
    fi
  fi

  # Для зеркала приоритетно используем каталог из целевой папки зеркала
  if [[ -r "$mirror_catalog" ]]; then
    echo "📋 Используется каталог из зеркала: $mirror_catalog"
    CATALOG="$mirror_catalog"
  elif [[ -r "$CATALOG" ]]; then
    echo "📋 Используется системный каталог: $CATALOG"
  else
    echo "⚠️ Каталог не найден ни в зеркале ($mirror_catalog), ни в системе ($CATALOG)" >&2
    if [[ $FETCH_CATALOG_API -eq 1 ]]; then
      echo "🔄 Автоматическое получение каталога через API Ubiquiti..." >&2
      if fetch_and_convert_firmware_api "$mirror_catalog" "$REWRITE_CATALOG_HOST"; then
        echo "✅ Каталог успешно получен через API: $mirror_catalog"
        CATALOG="$mirror_catalog"
        APP_VERSION="mirror"
      else
        echo "❌ Не удалось получить каталог через API" >&2
        exit 1
      fi
    else
      echo "🔄 Автоматическая загрузка каталога с $CATALOG_URL..." >&2
      echo "⚠️ ВНИМАНИЕ: URL $CATALOG_URL может быть недоступен (403 Forbidden)" >&2
      echo "💡 Подсказка: используйте --fetch-catalog-api для получения через API Ubiquiti" >&2
      if update_catalog "$CATALOG_URL" "$mirror_catalog" "$REWRITE_CATALOG_HOST" "0"; then
        echo "✅ Каталог успешно загружен: $mirror_catalog"
        CATALOG="$mirror_catalog"
      else
        echo "❌ Не удалось загрузить каталог" >&2
        echo "💡 Попробуйте с флагом --fetch-catalog-api" >&2
        exit 1
      fi
    fi
  fi

  auto_detect_app_version

  # Определить каталог для скачивания (с оригинальными ссылками)
  local ubnt_catalog="$root/firmware.ubnt.json"
  local download_catalog="$CATALOG"
  if [[ -r "$ubnt_catalog" ]]; then
    download_catalog="$ubnt_catalog"
    echo "⬇️ Скачивание по оригинальным ссылкам: $ubnt_catalog"
  else
    echo "⬇️ Скачивание по каталогу: $download_catalog"
  fi

  local jq_filter='.[$v].release | to_entries[] | .value.url + "\t" + .value.md5sum'
  if [[ -n "$FILTER_REGEX" ]]; then
      echo "Зеркалирование (filter: '$FILTER_REGEX')..."
      jq_filter=".[\$v].release | to_entries[] | select(.key | test(\"$FILTER_REGEX\")) | .value.url + \"\t\" + .value.md5sum"
  else
      echo "Зеркалирование (ВСЕ файлы)..."
  fi

  jq -r --arg v "$APP_VERSION" "$jq_filter" "$download_catalog" | \
  while IFS=$'\t' read -r url md5sum; do
    [[ -z "$url" || "$url" == "null" ]] && continue

    # FIX: Разделяем объявление переменных, чтобы избежать unbound variable в set -u
    local rel_path
    rel_path="${url#*://*/}"

    local dst
    dst="$root/$rel_path"

    if [[ -f "$dst" ]]; then
      local local_md5; local_md5=$(md5sum "$dst" | awk '{print $1}')
      if [[ "$local_md5" == "$md5sum" ]]; then continue; fi
    fi
    queue_download "$url" "$dst"
  done

  process_download_queue
  echo "Зеркалирование завершено."
}

process_manual_sources() {
  if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]]; then
    shopt -s nullglob
    for f in "$SRC_DIR"/*.bin "$SRC_DIR"/*.tar; do
      local code ver; IFS='|' read -r code ver < <(infer_family_version "$f")
      [[ -n "$code" && -n "$ver" ]] && {
        local dst="$UNIFI_FW_DIR/$code/$ver/$(basename "$f")"
        install_file "$f" "$dst"

        # Поиск совместимых устройств
        local md5; md5="$(md5sum "$dst" | awk '{print $1}')"
        local compat_devices; compat_devices=$(find_compatible_devices "$f" "$md5" "$ver")
        local devices="${compat_devices:-$code}"  # fallback к определённому коду

        add_meta_buffer "$code/$ver/$(basename "$f")" "$ver" "$devices" "$dst"
        echo "[LOCAL] $code $ver (devices: $devices) <- $f"
      }
    done
    shopt -u nullglob
  fi

  # Сбор информации о скачиваемых URL для последующего добавления метаданных
  local -a downloaded_urls=()

  for s in "${EXTRA_SOURCES[@]+"${EXTRA_SOURCES[@]}"}"; do
     local code ver; IFS='|' read -r code ver < <(infer_family_version "$s")
     if [[ "$s" =~ ^https?:// ]]; then
       if [[ -n "$code" && -n "$ver" ]]; then
         local dst="$UNIFI_FW_DIR/$code/$ver/$(basename "$s")"
         queue_download "$s" "$dst"
         downloaded_urls+=("$code|$ver|$dst|$s")  # сохраняем URL для поиска
       fi
     else
       [[ -n "$code" && -n "$ver" ]] && {
         local dst="$UNIFI_FW_DIR/$code/$ver/$(basename "$s")"
         install_file "$s" "$dst"

         # Поиск совместимых устройств
         local md5; md5="$(md5sum "$dst" | awk '{print $1}')"
         local compat_devices; compat_devices=$(find_compatible_devices "$s" "$md5" "$ver")
         local devices="${compat_devices:-$code}"

         add_meta_buffer "$code/$ver/$(basename "$s")" "$ver" "$devices" "$dst"
         echo "[FILE] $code $ver (devices: $devices) <- $s"
       }
     fi
  done
  for pair in "${SRC_URL_PAIRS[@]+"${SRC_URL_PAIRS[@]}"}"; do
    local url="${pair%%|*}" file="${pair#*|}" code ver
    IFS='|' read -r code ver < <(infer_family_version "$url")
    if [[ -n "$code" && -n "$ver" && -f "$file" ]]; then
       local dst="$UNIFI_FW_DIR/$code/$ver/$(basename "$url")"
       install_file "$file" "$dst"

       # Поиск совместимых устройств
       local md5; md5="$(md5sum "$dst" | awk '{print $1}')"
       local compat_devices; compat_devices=$(find_compatible_devices "$url" "$md5" "$ver")
       local devices="${compat_devices:-$code}"

       add_meta_buffer "$code/$ver/$(basename "$url")" "$ver" "$devices" "$dst"
       echo "[SRC-URL] $code $ver (devices: $devices) <- $file"
    fi
  done

  process_download_queue

  # Добавление метаданных для скачанных файлов
  for entry in "${downloaded_urls[@]+"${downloaded_urls[@]}"}"; do
    IFS='|' read -r code ver dst url <<< "$entry"
    if [[ -f "$dst" ]]; then
      local rel_path="$code/$ver/$(basename "$dst")"

      # Поиск совместимых устройств
      local md5; md5="$(md5sum "$dst" | awk '{print $1}')"
      local compat_devices; compat_devices=$(find_compatible_devices "$url" "$md5" "$ver")
      local devices="${compat_devices:-$code}"

      add_meta_buffer "$rel_path" "$ver" "$devices" "$dst"
      echo "[URL] $code $ver (devices: $devices) <- $(basename "$dst")"
    fi
  done
}

main() {
  # Режим обновления каталога (только обновить и выйти)
  if [[ $UPDATE_CATALOG -eq 1 && $MIRROR_ALL -eq 0 ]]; then
    echo "🔄 Режим обновления каталога"
    if ! is_root; then echo "⚠️ Требуются права root для обновления системного каталога." >&2; fi
    update_catalog "$CATALOG_URL" "$CATALOG" "$REWRITE_CATALOG_HOST" "$CATALOG_BACKUP"
    exit $?
  fi

  # Автообновление каталога перед основной логикой
  if [[ $AUTO_UPDATE_CATALOG -eq 1 ]]; then
    if ! check_catalog_age "$CATALOG" "$MAX_CATALOG_AGE"; then
      echo "🔄 Автообновление каталога..."
      update_catalog "$CATALOG_URL" "$CATALOG" "$REWRITE_CATALOG_HOST" "$CATALOG_BACKUP" || echo "⚠️ Не удалось обновить каталог, используется старый"
    fi
  fi

  if [[ $FROM_CATALOG -eq 1 || -n "$SRC_DIR" || ${#EXTRA_SOURCES[@]} -gt 0 || ${#SRC_URL_PAIRS[@]} -gt 0 ]]; then NEED_CONTROLLER=1; fi
  if [[ $NEED_CONTROLLER -eq 1 ]] && ! is_root; then echo "Требуются права root для режима контроллера." >&2; exit 1; fi
  # Для FROM_CATALOG вызываем auto_detect_app_version здесь
  # Для MIRROR_ALL это делается внутри mirror_all() после установки каталога
  if [[ $FROM_CATALOG -eq 1 ]] && [[ -z "$APP_VERSION" || "$APP_VERSION" == "auto" ]]; then auto_detect_app_version; fi

  if [[ $FROM_CATALOG -eq 1 ]]; then process_from_catalog; fi
  process_manual_sources
  if [[ $MIRROR_ALL -eq 1 ]]; then mirror_all; fi

  if [[ $NEED_CONTROLLER -eq 1 ]]; then
    commit_meta
    chown -R "$UNIFI_USER:$UNIFI_GROUP" "$UNIFI_FW_DIR"
    find "$UNIFI_FW_DIR" -type f -exec chmod 0644 {} +
    if [[ "$RESTART" == "1" ]]; then echo "Перезапуск unifi..."; systemctl restart unifi || echo "Ошибка перезапуска unifi" >&2; fi
    echo "Готово."
  fi
}

main "$@"
