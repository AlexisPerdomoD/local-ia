#!/usr/bin/env bash
# install.sh — instalación base del stack Ollama + Vulkan en Arch Linux
#
# Uso:
#   ./install.sh                                    # paquetes + servicio
#   ./install.sh --profile autocomplete             # + perfil de systemd
#   ./install.sh --profile autocomplete --models qwen2.5-coder:1.5b
#   ./install.sh --neovim                           # + config de minuet
#   ./install.sh --all                              # todo lo anterior
#   ./install.sh --dry-run --all                    # sólo mostrar comandos
#
# Todo es idempotente: se puede volver a ejecutar sin romper nada.
# Los pasos opcionales se delegan en scripts/ollama-profile.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=""
MODELS=()
INSTALL_NEOVIM=0
DRY_RUN=0

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
run()  {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
install.sh — stack Ollama local para Arch Linux + AMD (Vulkan)

Opciones:
  --profile NOMBRE   Aplica un perfil de profiles/ al servicio (sudo)
  --models M1 [M2]   Descarga modelos con `ollama pull` (hasta el siguiente flag)
  --neovim           Copia nvim/minuet.lua a ~/.config/nvim/lua/plugins/
  --all              --profile autocomplete --neovim
  --dry-run          Muestra lo que haría, sin ejecutar ni escribir
  -h, --help         Esta ayuda

Sin opciones sólo instala paquetes y habilita el servicio.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="${2:?falta el nombre del perfil}"; shift 2 ;;
        --models)
            shift
            while [[ $# -gt 0 && "$1" != -* ]]; do MODELS+=("$1"); shift; done
            ;;
        --neovim)  INSTALL_NEOVIM=1; shift ;;
        --all)     [[ -n "$PROFILE" ]] || PROFILE="autocomplete"; INSTALL_NEOVIM=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "opción desconocida: $1 (usa --help)" ;;
    esac
done

[[ -f /etc/arch-release ]] || die "este script asume Arch Linux (/etc/arch-release)"

if [[ $DRY_RUN -eq 0 ]]; then
    sudo -v || die "se necesita sudo"
fi

info "Paquetes"
run sudo pacman -S --needed --noconfirm ollama-vulkan vulkan-radeon vulkan-tools

info "Vulkan"
if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] vulkaninfo --summary\n'
else
    vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|apiVersion' || \
        printf '  aviso: vulkaninfo no reporta dispositivos\n'
fi

info "GPU detectada"
lspci -nn | grep -iE 'vga|3d|display' || printf '  aviso: no se detecta GPU\n'

info "Permisos del usuario del servicio"
run sudo usermod -aG render,video ollama
getent group render video || true

info "Servicio"
run sudo systemctl enable --now ollama.service

if [[ $DRY_RUN -eq 0 ]]; then
    systemctl --no-pager --lines=0 status ollama.service || true
    printf '\n'
    ollama --version
fi

info "API"
if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] curl -fsS http://127.0.0.1:11434/api/tags\n'
else
    for i in $(seq 1 20); do
        if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version; then
            printf '\n'
            break
        fi
        sleep 1
        [[ $i -eq 20 ]] && die "la API no respondió; revisa: journalctl -u ollama.service -n 50"
    done
fi

if [[ ${#MODELS[@]} -gt 0 ]]; then
    info "Modelos"
    for m in "${MODELS[@]}"; do
        run ollama pull "$m"
    done
fi

if [[ -n "$PROFILE" ]]; then
    info "Perfil de configuración: $PROFILE"
    profile_args=(apply "$PROFILE")
    [[ $DRY_RUN -eq 1 ]] && profile_args+=(--dry-run)
    run "$SCRIPT_DIR/scripts/ollama-profile.sh" "${profile_args[@]}"
fi

if [[ $INSTALL_NEOVIM -eq 1 ]]; then
    info "Configuración de Neovim (minuet)"
    destdir="${XDG_CONFIG_HOME:-$HOME/.config}/nvim/lua/plugins"
    dest="$destdir/minuet.lua"
    if [[ -e "$dest" ]]; then
        bak="$dest.bak.$(date +%Y%m%d-%H%M%S)"
        printf '  ya existe %s → backup en %s\n' "$dest" "$bak"
        run mv "$dest" "$bak"
    fi
    run mkdir -p "$destdir"
    run cp "$SCRIPT_DIR/nvim/minuet.lua" "$dest"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] se instalaría en %s\n' "$dest"
    else
        printf '  instalado: %s\n' "$dest"
    fi
    printf '  recuerda desactivar cualquier otro plugin de autocompletado inline\n'
fi

info "Listo"
cat <<EOF
Comprobaciones útiles:
  ./scripts/healthcheck.sh
  ./scripts/bench.sh
  ./scripts/ollama-profile.sh current

Si acabas de aplicar un perfil, el modelo aún no está en VRAM:
  ./scripts/ollama-profile.sh apply ${PROFILE:-autocomplete} --preload
EOF
