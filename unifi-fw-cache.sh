#!/usr/bin/env bash
set -euo pipefail
#
# unifi-fw-cache.sh — единый сценарий для офлайн-кэша прошивок UniFi.
# Поддерживает два основных потока:
#   1) Режим контроллера (кэш UniFi):
#      - --from-catalog + --codes "U7PG2 UAP6MP ..." — читать /var/lib/unifi/firmware.json
#        и wget'ом скачивать прошивки нужных устройств.
#      - --src-dir, позиционные URL/файлы, --src-url — докладывать прошивки в кэш контроллера.
#   2) Режим зеркала:
#      - --mirror-all [--mirror-root PATH] — скачать ВСЕ прошивки из firmware.json
#        в структуру data/unifi-firmware/... (как у fw-download.ubnt.com).
#
# Во всех режимах контроллера скрипт:
#   - раскладывает файлы как <UNIFI_FW_DIR>/<CODE>/<VERSION>/<FILENAME>;
#   - обновляет firmware_meta.json (с бэкапом);
#   - выставляет владельца UNIFI_USER:UNIFI_GROUP;
#   - по умолчанию перезапускает службу unifi.
#
# Требования: bash, jq, wget, md5sum, coreutils, systemd (для режима контроллера).
#
# Примеры:
#   # Кэшируем прошивки для AC Pro, U6 Pro, U6 Lite из каталога контроллера
#   sudo ./unifi-fw-cache.sh --from-catalog --codes "U7PG2 UAP6MP UAPL6"
#
#   # То же, но скачивание идёт через внутренний зеркальный хост
#   sudo REWRITE_HOST=ubnt.nimbo78.ru \
#     ./unifi-fw-cache.sh --from-catalog --codes "UAP6MP UAL6"
#
#   # Полностью офлайн: файлы уже лежат рядом со скриптом
#   sudo ./unifi-fw-cache.sh --src-dir .
#
#   # Офлайн файл, но известен исходный URL (парсим family/version из URL)
#   sudo ./unifi-fw-cache.sh \
#     --src-url "https://dl.ui.com/unifi/firmware/UAL6/6.7.31.15618/BZ.mt7621_6.7.31+15618.250916.2118.bin" \
#     ./BZ.mt7621_6.7.31+15618.250916.2118.bin
#
#   # То же самое, но URL после файла — тоже работает
#   sudo ./unifi-fw-cache.sh \
#     ./BZ.mt7621_6.7.31+15618.250916.2118.bin \
#     --src-url "https://dl.ui.com/unifi/firmware/UAL6/6.7.31.15618/BZ.mt7621_6.7.31+15618.250916.2118.bin"
#
#   # Построить зеркало всех прошивок из firmware.json в /srv/unifi-mirror
#   ./unifi-fw-cache.sh --mirror-all --mirror-root /srv/unifi-mirror --catalog ./firmware.json
#
# Настройки по умолчанию можно переопределить переменными окружения
# (UNIFI_FW_DIR, UNIFI_USER, UNIFI_GROUP, APP_VERSION, CATALOG, RESTART, REWRITE_HOST, MIRROR_ROOT).

# --- Конфигурация по умолчанию ---
UNIFI_FW_DIR="${UNIFI_FW_DIR:-/var/lib/unifi/firmware}"
CATALOG="${CATALOG:-/var/lib/unifi/firmware.json}"
APP_VERSION="${APP_VERSION:-}"        # если пусто — автоопределим по ключам firmware.json
DEV_FAMILY="${DEV_FAMILY:-}"          # явная подсказка кода устройства
VERSION="${VERSION:-}"                # явная подсказка версии
UNIFI_USER="${UNIFI_USER:-unifi}"
UNIFI_GROUP="${UNIFI_GROUP:-unifi}"
RESTART="${RESTART:-1}"
REWRITE_HOST="${REWRITE_HOST:-}"      # переписать хост в URL при скачивании
MIRROR_ROOT="${MIRROR_ROOT:-.}"

SRC_DIR=""               # локальная папка с прошивками (для режима контроллера)
FROM_CATALOG=0           # брать прошивки из firmware.json по кодам устройств
MIRROR_ALL=0             # режим зеркала
CODES=()                 # коды устройств для --from-catalog
EXTRA_SOURCES=()         # дополнительные URL/файлы (позиционные аргументы)
SRC_URL_PAIRS=()         # пары "URL|LOCAL_FILE" для --src-url
LAST_FILE_INDEX=-1       # индекс последнего локального файла в EXTRA_SOURCES
NEED_CONTROLLER=0        # нужно ли трогать кэш контроллера

# --- Утилиты ---
ts() { date +%Y%m%d-%H%M%S; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [URL_or_FILE ...]

Режим контроллера (работа с кэшем UniFi):
  --from-catalog           брать прошивки из firmware.json по кодам устройств
  --codes "CODES"          список кодов устройств ("U7PG2 UAP6MP UAL6" и т.п.)
  --app-version VER        ключ версии контроллера в firmware.json (по умолчанию — авто)
  --catalog PATH           путь к firmware.json (по умолчанию: $CATALOG)

  --src-dir PATH           забрать *.bin/*.tar из локальной папки
  --src-url URL [FILE]     связать локальный FILE (или последний файловый аргумент) с URL;
                           family/version берутся из URL, содержимое — из файла
  URL_or_FILE ...          дополнительные URL или локальные файлы для кэширования

Режим зеркала (локальное зеркало репозитория прошивок):
  --mirror-all             скачать ВСЕ прошивки из firmware.json в локальную структуру
  --mirror-root PATH       корень зеркала (по умолчанию: $MIRROR_ROOT)

Подсказки для family/version:
  --dev-family CODE        явно задать DEV_FAMILY для всех файлов/URL
  --version VER            явно задать VERSION для всех файлов/URL

Прочее:
  --rewrite-host HOST      заменить хост в URL при скачивании (оставляя путь как есть)
  --no-restart             не перезапускать службу unifi (только режим контроллера)
  -h, --help               показать эту справку

Переменные окружения:
  UNIFI_FW_DIR, UNIFI_USER, UNIFI_GROUP, CATALOG, APP_VERSION,
  RESTART, REWRITE_HOST, MIRROR_ROOT, DEV_FAMILY, VERSION
EOF
}

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# --- Парсинг аргументов ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-catalog)
      FROM_CATALOG=1; shift ;;
    --codes)
      shift
      IFS=' ' read -r -a CODES <<< "${1:-}" || true
      shift || true ;;
    --app-version)
      shift
      APP_VERSION="${1:-$APP_VERSION}"; shift || true ;;
    --catalog)
      shift
      CATALOG="${1:-$CATALOG}"; shift || true ;;
    --src-dir)
      shift
      SRC_DIR="${1:-}"; shift || true ;;
    --src-url)
      shift
      src_url="${1:-}"
      if [[ -z "$src_url" ]]; then
        echo "--src-url требует URL" >&2
        exit 2
      fi
      shift || true
      if [[ $# -gt 0 && ! "$1" =~ ^- && ! "$1" =~ ^https?:// ]]; then
        # Вариант: --src-url URL FILE
        src_file="$1"
        SRC_URL_PAIRS+=("$src_url|$src_file")
        shift || true
      else
        # Вариант: FILE ... --src-url URL (берём последний файловый аргумент)
        if [[ $LAST_FILE_INDEX -ge 0 ]]; then
          src_file="${EXTRA_SOURCES[$LAST_FILE_INDEX]}"
          SRC_URL_PAIRS+=("$src_url|$src_file")
          unset "EXTRA_SOURCES[$LAST_FILE_INDEX]"
          LAST_FILE_INDEX=-1
        else
          echo "--src-url $src_url: не найден локальный файл (ни после ключа, ни ранее)" >&2
          exit 2
        fi
      fi
      ;;
    --mirror-all)
      MIRROR_ALL=1; shift ;;
    --mirror-root)
      shift
      MIRROR_ROOT="${1:-$MIRROR_ROOT}"; shift || true ;;
    --rewrite-host)
      shift
      REWRITE_HOST="${1:-}"; shift || true ;;
    --dev-family)
      shift
      DEV_FAMILY="${1:-}"; shift || true ;;
    --version)
      shift
      VERSION="${1:-}"; shift || true ;;
    --no-restart)
      RESTART=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2 ;;
    *)
      # позиционный аргумент: URL или локальный файл
      if [[ "$1" =~ ^https?:// ]]; then
        EXTRA_SOURCES+=("$1")
        LAST_FILE_INDEX=-1
      else
        EXTRA_SOURCES+=("$1")
        LAST_FILE_INDEX=$((${#EXTRA_SOURCES[@]}-1))
      fi
      shift ;;
  esac
done

# если после "--" ещё что-то осталось — тоже считаем это источниками
while [[ $# -gt 0 ]]; do
  if [[ "$1" =~ ^https?:// ]]; then
    EXTRA_SOURCES+=("$1")
    LAST_FILE_INDEX=-1
  else
    EXTRA_SOURCES+=("$1")
    LAST_FILE_INDEX=$((${#EXTRA_SOURCES[@]}-1))
  fi
  shift
done

# --- Проверка утилит ---
for cmd in jq wget md5sum stat install; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Требуется: $cmd" >&2; exit 1; }
done

# --- Функции работы с файлами/URL ---

rewrite_url() {
  local u="$1"
  if [[ -n "$REWRITE_HOST" ]]; then
    printf '%s\n' "$u" | sed -E "s#^(https?://)[^/]+#\1$REWRITE_HOST#"
  else
    printf '%s\n' "$u"
  fi
}

ensure_dir() {
  local dir="$1"
  if [[ $NEED_CONTROLLER -eq 1 ]]; then
    install -d -o "$UNIFI_USER" -g "$UNIFI_GROUP" -m 0755 "$dir"
  else
    mkdir -p "$dir"
  fi
}

install_file() {
  local src="$1" dst="$2" mode="${3:-0644}"
  ensure_dir "$(dirname "$dst")"
  if [[ $NEED_CONTROLLER -eq 1 ]]; then
    install -o "$UNIFI_USER" -g "$UNIFI_GROUP" -m "$mode" "$src" "$dst"
  else
    cp "$src" "$dst"
    chmod "$mode" "$dst"
  fi
}

backup_file() {
  [[ $NEED_CONTROLLER -eq 1 ]] || return 0
  local src="$1" bak="${1}.bak.$(ts)"
  install_file "$src" "$bak" 0644
  echo "Backup: $bak"
}

init_meta() {
  [[ $NEED_CONTROLLER -eq 1 ]] || return 0
  ensure_dir "$UNIFI_FW_DIR"
  META="$UNIFI_FW_DIR/firmware_meta.json"
  if [[ ! -f "$META" ]]; then
    local tmp; tmp="$(mktemp)"; echo '{"cached_firmwares":[]}' >"$tmp"
    install_file "$tmp" "$META" 0644; rm -f "$tmp"
  fi
}

add_meta() {
  [[ $NEED_CONTROLLER -eq 1 ]] || return 0
  local rel="$1" ver="$2" code="$3" file="$4"
  local md5 size tmp
  md5="$(md5sum "$file" | awk '{print $1}')"
  size="$(stat -c%s "$file")"
  backup_file "$META"
  tmp="$(mktemp)" && jq --arg path "$rel" '.cached_firmwares |= map(select(.path != $path))' "$META" >"$tmp" && install_file "$tmp" "$META" 0644 && rm -f "$tmp"
  tmp="$(mktemp)" && jq --arg md5 "$md5" --arg ver "$ver" --argjson size "$size" --arg path "$rel" --arg code "$code" \
     '.cached_firmwares += [ {md5:$md5, version:$ver, size:$size, path:$path, devices:[$code]} ]' \
     "$META" >"$tmp" && install_file "$tmp" "$META" 0644 && rm -f "$tmp"
}

download_wget() {
  local url="$1" dst="$2"
  local final_url tmp
  final_url="$(rewrite_url "$url")"
  tmp="$(mktemp)"
  wget --tries=3 --timeout=30 --continue --show-progress --output-document="$tmp" "$final_url"
  install_file "$tmp" "$dst" 0644
  rm -f "$tmp"
}

# Попытки угадать DEV_FAMILY и VERSION из URL/имени файла
infer_family_version() {
  local src="$1"
  local fname url_path family="" ver=""

  if [[ "$src" =~ ^https?:// ]]; then
    fname="$(basename "$src")"
    url_path="$(printf '%s' "$src" | sed -E 's#^https?://[^/]+##')"
    # Попытка 1: /firmware/<FAMILY>/<VERSION>/...
    if [[ "$url_path" =~ /firmware/([^/]+)/([^/]+)/[^/]+$ ]]; then
      family="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"
    fi
  else
    fname="$(basename "$src")"
  fi

  # Попытка 2: по сигнатуре в имени: -UAP6MP-, -UAPL6-, -UAL6-, -U7PG2-
  if [[ -z "$family" ]]; then
    [[ "$fname" =~ -UAP6MP- ]] && family="UAP6MP"
    [[ -z "$family" && "$fname" =~ -UAPL6- ]] && family="UAPL6"
    [[ -z "$family" && "$fname" =~ -UAL6-  ]] && family="UAL6"
    [[ -z "$family" && "$fname" =~ -U7PG2- ]] && family="U7PG2"
  fi

  # Попытка 3: версия как X.Y.Z или X.Y.Z.W из имени
  if [[ -z "$ver" ]]; then
    if [[ "$fname" =~ ([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
      ver="${BASH_REMATCH[1]}"
    fi
  fi

  # Перекрытие через env/флаги, если заданы
  family="${DEV_FAMILY:-$family}"
  ver="${VERSION:-$ver}"

  echo "$family|$ver"
}

place_and_index() {
  local code="$1" ver="$2" src="$3" fname="$4"
  local target_dir="$UNIFI_FW_DIR/$code/$ver"
  local target_file="$target_dir/$fname"
  local rel="$code/$ver/$fname"

  ensure_dir "$target_dir"
  if [[ ! -s "$src" ]]; then
    echo "Файл отсутствует или пуст: $src" >&2
    return 1
  fi
  install_file "$src" "$target_file" 0644
  add_meta "$rel" "$ver" "$code" "$target_file"
}

process_url() {
  local url="$1" fname code ver
  fname="$(basename "$url")"
  IFS='|' read -r code ver < <(infer_family_version "$url")
  if [[ -z "$code" || -z "$ver" ]]; then
    echo "Не удалось определить DEV_FAMILY/Version из URL или имени файла: $url. Подскажите через DEV_FAMILY и VERSION." >&2
    return 1
  fi
  local target_dir="$UNIFI_FW_DIR/$code/$ver"
  local target_file="$target_dir/$fname"
  ensure_dir "$target_dir"
  echo "[URL] $code $ver → $target_file"
  download_wget "$url" "$target_file"
  add_meta "$code/$ver/$fname" "$ver" "$code" "$target_file"
}

process_local() {
  local path="$1" base code ver
  base="$(basename "$path")"
  IFS='|' read -r code ver < <(infer_family_version "$path")
  if [[ -z "$code" || -z "$ver" ]]; then
    echo "Не удалось определить DEV_FAMILY/Version из файла: $path. Подскажите через DEV_FAMILY и VERSION." >&2
    return 1
  fi
  echo "[FILE] $code $ver ← $path"
  place_and_index "$code" "$ver" "$path" "$base"
}

process_local_with_src_url() {
  local url="$1" path="$2" fname code ver

  if [[ ! -s "$path" ]]; then
    echo "[SRC-URL] Файл не найден или пуст: $path" >&2
    return 1
  fi

  IFS='|' read -r code ver < <(infer_family_version "$url")
  if [[ -z "$code" || -z "$ver" ]]; then
    echo "[SRC-URL] Не удалось определить DEV_FAMILY/Version из URL: $url. Подскажите через DEV_FAMILY и VERSION." >&2
    return 1
  fi

  fname="$(basename "$url")"
  echo "[SRC-URL] $code $ver ← $path (URL: $url)"
  place_and_index "$code" "$ver" "$path" "$fname"
}

process_from_catalog() {
  [[ ${#CODES[@]} -gt 0 ]] || { echo "--from-catalog требует --codes \"...\"" >&2; return 2; }
  [[ -r "$CATALOG" ]] || { echo "Каталог не найден: $CATALOG" >&2; return 2; }

  for code in "${CODES[@]}"; do
    local ver url md5sum
    if ! read -r ver url md5sum < <(jq -r --arg v "$APP_VERSION" --arg c "$code" \
      '.[$v].release[$c] | select(.) | "\(.version) \(.url) \(.md5sum)"' "$CATALOG"); then
      echo "[$code] Ошибка чтения каталога для версии $APP_VERSION" >&2
      continue
    fi

    if [[ -z "${ver:-}" || -z "${url:-}" ]]; then
      echo "[$code] Нет записи в каталоге для версии $APP_VERSION — пропуск." >&2
      continue
    fi

    local fname target_dir target_file
    fname="$(basename "$url")"
    target_dir="$UNIFI_FW_DIR/$code/$ver"
    target_file="$target_dir/$fname"
    ensure_dir "$target_dir"

    echo "[CATALOG] $code $ver → $target_file"
    if [[ ! -s "$target_file" ]]; then
      download_wget "$url" "$target_file"
    else
      # Перевыставим права/владельца на случай, если файл пришёл не от скрипта
      install_file "$target_file" "$target_file" 0644
    fi

    if [[ -n "${md5sum:-}" && -s "$target_file" ]]; then
      local have
      have="$(md5sum "$target_file" | awk '{print $1}')"
      if [[ "$have" != "$md5sum" ]]; then
        echo "ВНИМАНИЕ: MD5 mismatch for $target_file (catalog=$md5sum, file=$have)" >&2
      fi
    fi

    add_meta "$code/$ver/$fname" "$ver" "$code" "$target_file"
  done
}

auto_detect_app_version() {
  [[ -n "$APP_VERSION" && "$APP_VERSION" != "auto" ]] && return 0
  [[ -r "$CATALOG" ]] || { echo "Невозможно автоопределить APP_VERSION: нет доступа к $CATALOG" >&2; exit 1; }
  APP_VERSION="$(jq -r 'keys[]' "$CATALOG" | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -n1 || true)"
  if [[ -z "$APP_VERSION" ]]; then
    echo "Не удалось автоопределить APP_VERSION из $CATALOG" >&2
    exit 1
  fi
  echo "APP_VERSION автоматически определена как $APP_VERSION" >&2
}

mirror_all() {
  [[ -r "$CATALOG" ]] || { echo "Каталог не найден: $CATALOG" >&2; return 2; }
  auto_detect_app_version

  local root="$MIRROR_ROOT"
  mkdir -p "$root"
  echo "Начинаем зеркалирование всех прошивок для версии $APP_VERSION в $root"

  jq -r --arg v "$APP_VERSION" '.[$v].release | to_entries[] | "\(.key) \(.value.version) \(.value.url) \(.value.md5sum)"' "$CATALOG" |
  while read -r code ver url md5sum; do
    [[ -z "$url" ]] && continue
    local rel_path dst
    rel_path="$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/##')"
    dst="$root/$rel_path"

    mkdir -p "$(dirname "$dst")"

    if [[ -s "$dst" ]]; then
      echo "[MIRROR] Уже есть: $rel_path — пропуск"
    else
      echo "[MIRROR] Скачиваем $code $ver → $rel_path"
      download_wget "$url" "$dst"
    fi

    if [[ -n "${md5sum:-}" && -s "$dst" ]]; then
      local have
      have="$(md5sum "$dst" | awk '{print $1}')"
      if [[ "$have" != "$md5sum" ]]; then
        echo "[MIRROR] MD5 mismatch для $rel_path (catalog=$md5sum, file=$have)" >&2
      fi
    fi
  done

  echo "Зеркало завершено: $root"
}

main() {
  # Определяем, нужен ли режим контроллера
  if [[ $FROM_CATALOG -eq 1 || -n "$SRC_DIR" || ${#EXTRA_SOURCES[@]} -gt 0 || ${#SRC_URL_PAIRS[@]} -gt 0 ]]; then
    NEED_CONTROLLER=1
  fi

  if [[ $NEED_CONTROLLER -eq 1 ]] && ! is_root; then
    echo "Режим контроллера требует root (нужно писать в $UNIFI_FW_DIR и рестартовать unifi)" >&2
    exit 1
  fi

  # Автоопределение версии контроллера при необходимости
  if { [[ $FROM_CATALOG -eq 1 ]] || [[ $MIRROR_ALL -eq 1 ]]; } && [[ -z "$APP_VERSION" || "$APP_VERSION" == "auto" ]]; then
    auto_detect_app_version
  fi

  init_meta

  # 1) Каталог
  if [[ $FROM_CATALOG -eq 1 ]]; then
    process_from_catalog
  fi

  # 2) Скан src-dir
  if [[ -n "$SRC_DIR" ]]; then
    [[ -d "$SRC_DIR" ]] || { echo "Папка не найдена: $SRC_DIR" >&2; exit 2; }
    shopt -s nullglob
    for f in "$SRC_DIR"/*.bin "$SRC_DIR"/*.tar; do
      [[ -e "$f" ]] || continue
      process_local "$f" || true
    done
    shopt -u nullglob
  fi

  # 3) Явно переданные источники (URL/FILES)
  if [[ ${#EXTRA_SOURCES[@]} -gt 0 ]]; then
    local s
    for s in "${EXTRA_SOURCES[@]}"; do
      [[ -z "$s" ]] && continue
      if [[ "$s" =~ ^https?:// ]]; then
        process_url "$s" || true
      else
        process_local "$s" || true
      fi
    done
  fi

  # 4) Пары URL+локальный файл (--src-url)
  if [[ ${#SRC_URL_PAIRS[@]} -gt 0 ]]; then
    local pair url file
    for pair in "${SRC_URL_PAIRS[@]}"; do
      url="${pair%%|*}"
      file="${pair#*|}"
      process_local_with_src_url "$url" "$file" || true
    done
  fi

  # 5) Режим зеркала (можно запускать отдельно, без контроллера/рута)
  if [[ $MIRROR_ALL -eq 1 ]]; then
    mirror_all
  fi

  if [[ $NEED_CONTROLLER -eq 1 ]]; then
    chown -R "$UNIFI_USER:$UNIFI_GROUP" "$UNIFI_FW_DIR"
    find "$UNIFI_FW_DIR" -type f -exec chmod 0644 {} +

    if [[ "$RESTART" == "1" ]]; then
      systemctl restart unifi || echo "Не удалось перезапустить службу unifi" >&2
    fi

    echo "Готово. Индекс: $UNIFI_FW_DIR/firmware_meta.json | Кэш: $UNIFI_FW_DIR"
    echo "Если UI не видит кэш — проверьте логи: grep -i firmware_meta /usr/lib/unifi/logs/server.log | tail -n 50"
  fi
}

main "$@"
