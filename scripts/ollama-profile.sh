#!/usr/bin/env bash
# ollama-profile.sh — aplica perfiles de variables de entorno a ollama.service
#
# Los perfiles viven en ../profiles/*.env y contienen líneas KEY=VALUE.
# Sólo las variables que empiezan por OLLAMA_ se escriben en systemd; el resto
# (por ejemplo OLLAMA_DEFAULT_MODEL) son metadatos que usan bench.sh y este
# mismo script para precargar el modelo correcto.
#
# Uso:
#   ./scripts/ollama-profile.sh list
#   ./scripts/ollama-profile.sh current
#   ./scripts/ollama-profile.sh show autocomplete
#   ./scripts/ollama-profile.sh apply autocomplete [--dry-run] [--preload] [--no-restart]
#
# Requiere sudo para escribir el drop-in de systemd y reiniciar el servicio.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROFILES_DIR="${OLLAMA_PROFILES_DIR:-$REPO_ROOT/profiles}"
SERVICE="ollama.service"
OVERRIDE="/etc/systemd/system/ollama.service.d/override.conf"
API="http://127.0.0.1:11434"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf 'aviso: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
ollama-profile.sh — cambia el perfil de configuración de Ollama

Comandos:
  list                        Lista los perfiles disponibles en profiles/
  current                     Muestra la configuración activa del servicio
  show <perfil>               Muestra el contenido de un perfil
  apply <perfil> [opciones]   Aplica un perfil al servicio

Opciones de apply:
  --dry-run      Muestra el drop-in resultante sin escribir nada
  --preload      Carga el modelo del perfil en VRAM al terminar
  --no-restart   Escribe el drop-in pero no reinicia el servicio

Ejemplos:
  ./scripts/ollama-profile.sh apply autocomplete
  ./scripts/ollama-profile.sh apply agent --dry-run
  ./scripts/ollama-profile.sh apply hybrid --preload
EOF
}

profile_file() {
    local name="${1%.env}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "nombre de perfil inválido: $1"
    local path="$PROFILES_DIR/$name.env"
    [[ -f "$path" ]] || die "no existe el perfil '$name' ($path)"
    printf '%s' "$path"
}

profile_value() {
    # profile_value <ruta> <CLAVE>  → imprime el valor (vacío si no existe)
    local file="$1" key="$2"
    sed -n "s/^${key}=//p" "$file" | tail -n 1
}

cmd_list() {
    [[ -d "$PROFILES_DIR" ]] || die "no existe $PROFILES_DIR"
    local file name desc
    shopt -s nullglob
    local files=("$PROFILES_DIR"/*.env)
    shopt -u nullglob
    [[ ${#files[@]} -gt 0 ]] || die "no hay perfiles en $PROFILES_DIR"

    printf '%-14s %-30s %s\n' "PERFIL" "MODELO" "DESCRIPCIÓN"
    for file in "${files[@]}"; do
        name="$(basename "$file" .env)"
        desc="$(sed -n '1s/^# *//p' "$file" | cut -c1-60)"
        printf '%-14s %-30s %s\n' \
            "$name" \
            "$(profile_value "$file" OLLAMA_DEFAULT_MODEL)" \
            "$desc"
    done
}

cmd_show() {
    [[ $# -ge 1 ]] || die "uso: $0 show <perfil>"
    local file
    file="$(profile_file "$1")"
    info "# $file"
    info ""
    cat "$file"
}

cmd_current() {
    info "== Servicio =="
    systemctl is-active "$SERVICE" >/dev/null 2>&1 \
        && info "$SERVICE: activo" \
        || warn "$SERVICE: NO activo"

    if [[ -f "$OVERRIDE" ]]; then
        info ""
        info "== Drop-in activo ($OVERRIDE) =="
        cat "$OVERRIDE"
    else
        warn "no existe $OVERRIDE (configuración por defecto del paquete)"
    fi

    info ""
    info "== Variables efectivas =="
    systemctl show "$SERVICE" -p Environment --value 2>/dev/null \
        | tr ' ' '\n' | grep '^OLLAMA_' | sort || info "(ninguna)"

    info ""
    info "== Modelos en memoria =="
    ollama ps 2>/dev/null || warn "no se pudo consultar la API"

    info ""
    info "Pista: compara con '$(basename "$0") list' y aplica el perfil que quieras"
}

cmd_apply() {
    [[ $# -ge 1 ]] || die "uso: $0 apply <perfil> [--dry-run] [--preload] [--no-restart]"

    local name="${1%.env}"; shift
    local dry_run=0 preload=0 restart=1
    for arg in "$@"; do
        case "$arg" in
            --dry-run)    dry_run=1 ;;
            --preload)    preload=1 ;;
            --no-restart) restart=0 ;;
            *) die "opción desconocida: $arg" ;;
        esac
    done

    local file model tmp
    file="$(profile_file "$name")"
    model="$(profile_value "$file" OLLAMA_DEFAULT_MODEL)"

    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    {
        echo "# Generado por scripts/ollama-profile.sh desde profiles/$name.env"
        echo "# Perfil: $name"
        echo "# Fecha:  $(date -Iseconds)"
        echo "# Revertir: restaurar override.conf.bak.* y 'systemctl daemon-reload'"
        echo "[Service]"
        grep -E '^OLLAMA_[A-Z0-9_]+=' "$file" \
            | grep -v '^OLLAMA_DEFAULT_MODEL=' \
            | sed -E 's/^(OLLAMA_[A-Z0-9_]+)=(.*)$/Environment="\1=\2"/'
    } >"$tmp"

    info "== Drop-in resultante para el perfil '$name' =="
    cat "$tmp"
    info ""

    if [[ $dry_run -eq 1 ]]; then
        info "--dry-run: no se escribe nada."
        exit 0
    fi

    sudo -v || die "se necesita sudo para escribir $OVERRIDE"

    if [[ -f "$OVERRIDE" ]]; then
        local backup="${OVERRIDE}.bak.$(date +%Y%m%d-%H%M%S)"
        info "backup: $backup"
        sudo cp -a "$OVERRIDE" "$backup"
    fi

    sudo install -D -m 0644 "$tmp" "$OVERRIDE"
    info "escrito: $OVERRIDE"

    sudo systemctl daemon-reload
    info "daemon-reload: ok"

    if [[ $restart -eq 0 ]]; then
        warn "--no-restart: los cambios no están activos todavía"
        warn "ejecuta: sudo systemctl restart $SERVICE"
        exit 0
    fi

    info "reiniciando $SERVICE..."
    sudo systemctl restart "$SERVICE"

    # Espera a que la API responda.
    local i
    for i in $(seq 1 30); do
        if curl -fsS --max-time 2 "$API/api/version" >/dev/null 2>&1; then
            info "API lista tras ${i}s: $(curl -fsS "$API/api/version")"
            break
        fi
        sleep 1
        [[ $i -eq 30 ]] && die "la API no respondió en 30s; revisa: journalctl -u $SERVICE -n 50"
    done

    if [[ -n "$model" ]]; then
        info ""
        info "modelo por defecto del perfil: $model"
        if [[ $preload -eq 1 ]]; then
            info "precargando $model..."
            local keep_alive
            keep_alive="$(profile_value "$file" OLLAMA_KEEP_ALIVE)"
            [[ -n "$keep_alive" ]] || keep_alive="30m"
            curl -fsS "$API/api/generate" \
                -d "$(printf '{"model":"%s","prompt":"","stream":false,"keep_alive":"%s"}' "$model" "$keep_alive")" \
                >/dev/null
            info "precarga completada"
        else
            info "(usa --preload para cargarlo en VRAM ahora)"
        fi
        printf '\n'
        ollama ps 2>/dev/null || true
    fi
}

main() {
    [[ $# -ge 1 ]] || { usage; exit 1; }
    local cmd="$1"; shift
    case "$cmd" in
        list)            cmd_list "$@" ;;
        current)         cmd_current "$@" ;;
        show)            cmd_show "$@" ;;
        apply)           cmd_apply "$@" ;;
        -h|--help|help)  usage ;;
        *)               die "comando desconocido: $cmd (usa --help)" ;;
    esac
}

main "$@"
