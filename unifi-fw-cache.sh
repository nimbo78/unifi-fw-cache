#!/usr/bin/env bash
set -euo pipefail

# unifi-fw-cache.sh (v5 - Stable Mirror)

# --- Конфигурация по умолчанию ---
UNIFI_FW_DIR="${UNIFI_FW_DIR:-/var/lib/unifi/firmware}"
CATALOG="${CATALOG:-/var/lib/unifi/firmware.json}"
APP_VERSION="${APP_VERSION:-}"
DEV_FAMILY="${DEV_FAMILY:-}"
VERSION="${VERSION:-}"
UNIFI_USER="${UNIFI_USER:-unifi}"
UNIFI_GROUP="${UNIFI_GROUP:-unifi}"
RESTART="${RESTART:-1}"
REWRITE_HOST="${REWRITE_HOST:-}"
MIRROR_ROOT="${MIRROR_ROOT:-.}"
DOWNLOAD_THREADS="${DOWNLOAD_THREADS:-5}"

SRC_DIR=""
FROM_CATALOG=0
MIRROR_ALL=0
CODES=()
EXTRA_SOURCES=()
SRC_URL_PAIRS=()
LAST_FILE_INDEX=-1
NEED_CONTROLLER=0
FILTER_REGEX="" 

# Временные файлы
TEMP_META_FILE="$(mktemp)"
DOWNLOAD_LIST="$(mktemp)"

cleanup() { rm -f "$TEMP_META_FILE" "$DOWNLOAD_LIST"; }
trap cleanup EXIT

# --- Утилиты ---
ts() { date +%Y%m%d-%H%M%S; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [URL_or_FILE ...]

Режим контроллера:
  --from-catalog           кэшировать прошивки в /var/lib/unifi/firmware
  --filter "REGEX"         фильтр (напр. "^(UAP|US)" для AP и Switch)
  --codes "CODES"          список кодов вручную ("U7PG2 UAP6MP")
  
Режим зеркала:
  --mirror-all             создать зеркало файлов
  --mirror-root PATH       путь для зеркала (напр. /root/unifi-cache)

Опции:
  --threads N              потоков (default: 5)
  --no-restart             не перезапускать unifi
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
    --dev-family) shift; DEV_FAMILY="${1:-}"; shift || true ;;
    --version) shift; VERSION="${1:-}"; shift || true ;;
    --threads) shift; DOWNLOAD_THREADS="${1:-5}"; shift || true ;;
    --no-restart) RESTART=0; shift ;;
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
  if [[ "$1" =~ ^https?:// ]]; then EXTRA_SOURCES+=("$1"); else EXTRA_SOURCES+=("$1"); fi
  shift
done

for cmd in jq wget md5sum stat install xargs; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Требуется: $cmd" >&2; exit 1; }
done

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

  local devices=""

  # Приоритет 1: Поиск по MD5 (самый надёжный)
  if [[ -n "$md5" ]]; then
    devices=$(jq -r --arg v "$app_version" --arg md5 "$md5" '
      .[$v].release | to_entries[] | select(.value.md5sum == $md5) | .key
    ' "$catalog" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' || true)
  fi

  # Приоритет 2: Поиск по имени файла и версии
  if [[ -z "$devices" && -n "$url" && -n "$ver" ]]; then
    local filename; filename="$(basename "$url")"
    devices=$(jq -r --arg v "$app_version" --arg fname "$filename" --arg fver "$ver" '
      .[$v].release | to_entries[] |
      select(.value.url | endswith($fname)) |
      select(.value.version == $fver) |
      .key
    ' "$catalog" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' || true)
  fi

  # Приоритет 3: Поиск только по имени файла
  if [[ -z "$devices" && -n "$url" ]]; then
    local filename; filename="$(basename "$url")"
    devices=$(jq -r --arg v "$app_version" --arg fname "$filename" '
      .[$v].release | to_entries[] |
      select(.value.url | endswith($fname)) |
      .key
    ' "$catalog" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' || true)
  fi

  echo "$devices"
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
  
  local tmp_dst="${dst}.tmp"
  mkdir -p "$(dirname "$dst")"
  echo "Download: .../$(basename "$dst")"
  if wget -q -c -O "$tmp_dst" --tries=3 --timeout=30 "$url"; then 
    mv -f "$tmp_dst" "$dst"
  else 
    echo "FAIL: $url" >&2
    rm -f "$tmp_dst"
    exit 1
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
    [[ "$fname_base" =~ -UAP6MP- ]] && family="UAP6MP"
    [[ -z "$family" && "$fname_base" =~ -UAPL6- ]] && family="UAPL6"
    [[ -z "$family" && "$fname_base" =~ -UAL6-  ]] && family="UAL6"
    [[ -z "$family" && "$fname_base" =~ -U7PG2- ]] && family="U7PG2"
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
        add_meta_buffer "$rel_path" "$ver" "$code" "$target_file"
      fi
    fi
    [[ $need_download -eq 1 ]] && queue_download "$url" "$target_file"
  done <<< "$tasks"

  process_download_queue

  while IFS=$'\t' read -r code ver url md5sum; do
    local fname target_file rel_path
    fname="$(basename "$url")"; target_file="$UNIFI_FW_DIR/$code/$ver/$fname"; rel_path="$code/$ver/$fname"
    if [[ -f "$target_file" ]]; then
       [[ "$(md5sum "$target_file" | awk '{print $1}')" == "$md5sum" ]] && add_meta_buffer "$rel_path" "$ver" "$code" "$target_file"
    fi
  done <<< "$tasks"
}

mirror_all() {
  [[ -r "$CATALOG" ]] || { echo "Каталог не найден" >&2; exit 1; }
  auto_detect_app_version
  local root="$MIRROR_ROOT"
  
  local jq_filter='.[$v].release | .[].url + "\t" + .[].md5sum'
  if [[ -n "$FILTER_REGEX" ]]; then
      echo "Зеркалирование (filter: '$FILTER_REGEX')..."
      jq_filter=".[\$v].release | to_entries[] | select(.key | test(\"$FILTER_REGEX\")) | .value.url + \"\t\" + .value.md5sum"
  else
      echo "Зеркалирование (ВСЕ файлы)..."
  fi

  jq -r --arg v "$APP_VERSION" "$jq_filter" "$CATALOG" | \
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

  for s in "${EXTRA_SOURCES[@]}"; do
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
  for pair in "${SRC_URL_PAIRS[@]}"; do
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
  for entry in "${downloaded_urls[@]}"; do
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
  if [[ $FROM_CATALOG -eq 1 || -n "$SRC_DIR" || ${#EXTRA_SOURCES[@]} -gt 0 || ${#SRC_URL_PAIRS[@]} -gt 0 ]]; then NEED_CONTROLLER=1; fi
  if [[ $NEED_CONTROLLER -eq 1 ]] && ! is_root; then echo "Требуются права root для режима контроллера." >&2; exit 1; fi
  if { [[ $FROM_CATALOG -eq 1 ]] || [[ $MIRROR_ALL -eq 1 ]]; } && [[ -z "$APP_VERSION" || "$APP_VERSION" == "auto" ]]; then auto_detect_app_version; fi

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
