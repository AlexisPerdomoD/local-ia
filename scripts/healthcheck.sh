#!/usr/bin/env bash
# healthcheck.sh — verifica que el stack local (GPU + Ollama + modelos) está sano
#
# Comprobaciones:
#   1. GPU AMD visible y VRAM total
#   2. Paquetes relevantes instalados
#   3. Servicio ollama activo y API respondiendo
#   4. Variables de entorno efectivas del servicio
#   5. Modelos instalados y modelos cargados en VRAM
#   6. Espacio en disco del directorio de modelos
#   7. Coherencia de la configuración (avisos de tuning)
#
# Salida legible, sin efectos secundarios. Exit code 1 si algo crítico falla.

set -Eeuo pipefail

API="${OLLAMA_API:-http://127.0.0.1:11434}"
MODELS_DIR="/var/lib/ollama"
FAIL=0
WARN=0

ok()   { printf '  [ok]    %s\n' "$*"; }
warn() { printf '  [aviso] %s\n' "$*"; WARN=$((WARN + 1)); }
bad()  { printf '  [fallo] %s\n' "$*"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s ==\n' "$*"; }

section "Sistema"
if [[ -f /etc/arch-release ]]; then
    ok "Arch Linux"
else
    warn "no parece Arch Linux (los comandos pacman de este repo no aplican)"
fi
printf '  kernel:  %s\n' "$(uname -r)"
printf '  ollama:  %s\n' "$(ollama --version 2>&1 | head -1)"

section "GPU"
gpu_line="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -1 || true)"
if [[ -n "$gpu_line" ]]; then
    ok "${gpu_line#*: }"
else
    bad "no se detecta GPU en lspci"
fi
for card in /sys/class/drm/card*/device/mem_info_vram_total; do
    [[ -f "$card" ]] || continue
    printf '  VRAM:    %s MiB (%s)\n' "$(( $(cat "$card") / 1024 / 1024 ))" "$card"
done
if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary 2>/dev/null | grep -qi 'deviceName'; then
        ok "Vulkan operativo"
    else
        warn "vulkaninfo no lista dispositivos"
    fi
else
    warn "vulkaninfo no instalado (paquete vulkan-tools)"
fi

section "Paquetes"
for pkg in ollama ollama-vulkan vulkan-radeon; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
        ok "$pkg $(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')"
    else
        warn "$pkg no instalado"
    fi
done

section "Servicio"
if systemctl is-active --quiet ollama.service; then
    ok "ollama.service activo"
else
    bad "ollama.service inactivo (sudo systemctl start ollama.service)"
fi
if systemctl is-enabled --quiet ollama.service 2>/dev/null; then
    ok "ollama.service habilitado al arranque"
else
    warn "ollama.service no habilitado al arranque"
fi

if version="$(curl -fsS --max-time 3 "$API/api/version" 2>/dev/null)"; then
    ok "API responde: $version"
else
    bad "API no responde en $API"
fi

section "Configuración efectiva"
env_dump="$(systemctl show ollama.service -p Environment --value 2>/dev/null || true)"
if [[ -z "$env_dump" ]]; then
    warn "el servicio no define variables propias (usa defaults del paquete)"
else
    printf '%s\n' "$env_dump" | tr ' ' '\n' | grep '^OLLAMA_' | sort | sed 's/^/  /'
fi

ctx="$(printf '%s\n' "$env_dump" | tr ' ' '\n' | sed -n 's/^OLLAMA_CONTEXT_LENGTH=//p')"
kl="$(printf '%s\n' "$env_dump" | tr ' ' '\n' | sed -n 's/^OLLAMA_KEEP_ALIVE=//p')"
ml="$(printf '%s\n' "$env_dump" | tr ' ' '\n' | sed -n 's/^OLLAMA_MAX_LOADED_MODELS=//p')"

[[ -n "$ctx" ]] && ok "contexto global: $ctx tokens" || warn "OLLAMA_CONTEXT_LENGTH sin fijar (Ollama elegirá según VRAM)"
if [[ -z "$kl" ]]; then
    warn "OLLAMA_KEEP_ALIVE sin fijar: el modelo se descarga a los 5 min (cold start)"
elif [[ "$kl" == "-1" ]]; then
    warn "OLLAMA_KEEP_ALIVE=-1: el modelo nunca se descarga (vigila VRAM libre)"
else
    ok "keep_alive: $kl"
fi
if [[ -n "$ml" && "$ml" -lt 2 ]]; then
    warn "OLLAMA_MAX_LOADED_MODELS=$ml: un solo modelo en memoria; cambiar de modelo fuerza recarga"
fi

section "Modelos instalados"
if ! ollama list 2>/dev/null; then
    bad "no se pudo listar modelos"
fi

section "Modelos en memoria"
if ps_out="$(ollama ps 2>/dev/null)"; then
    printf '%s\n' "$ps_out" | sed 's/^/  /'
    if printf '%s\n' "$ps_out" | grep -q 'CPU'; then
        warn "algún modelo está usando CPU: se está haciendo offloading (revisa VRAM)"
    fi
else
    warn "no se pudo consultar ollama ps"
fi

section "Disco"
if [[ -d "$MODELS_DIR" ]]; then
    df -h "$MODELS_DIR" 2>/dev/null | awk 'NR==2{printf "  modelos: %s libres de %s (%s usado)\n", $4, $2, $5}'
    use="$(df --output=pcent "$MODELS_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
    [[ -n "$use" && "$use" -gt 90 ]] && warn "disco por encima del ${use}%"
else
    warn "$MODELS_DIR no existe (¿OLLAMA_MODELS apunta a otro sitio?)"
fi

section "Resumen"
if [[ $FAIL -gt 0 ]]; then
    printf '  %d fallo(s), %d aviso(s)\n' "$FAIL" "$WARN"
    exit 1
fi
printf '  sin fallos, %d aviso(s)\n' "$WARN"
