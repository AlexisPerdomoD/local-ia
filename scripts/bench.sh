#!/usr/bin/env bash
# bench.sh — mide latencia de autocompletado (FIM) contra Ollama local
#
# Mide dos escenarios sobre la misma petición:
#   * frío: modelo descargado de VRAM antes de la prueba (peor caso real)
#   * caliente: segunda petición consecutiva (caso normal en edición)
#
# Métricas: TTFT (time to first token) y tokens/s de generación.
#
# Uso:
#   ./scripts/bench.sh                          # modelo del perfil activo
#   ./scripts/bench.sh qwen2.5-coder:7b
#   ./scripts/bench.sh --ctx 8192 --tokens 64
#   ./scripts/bench.sh --warm-only
#
# Requiere: curl, python3, y que ollama.service esté activo.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
API="${OLLAMA_API:-http://127.0.0.1:11434}"
OVERRIDE="/etc/systemd/system/ollama.service.d/override.conf"

MODEL=""
CTX="4096"
TOKENS="64"
COLD=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
bench.sh — benchmark de autocompletado FIM

Uso: ./scripts/bench.sh [modelo] [opciones]

Opciones:
  --ctx N        num_ctx de la petición (default 4096)
  --tokens N     tokens máximos a generar (default 64)
  --warm-only    no descarga el modelo antes de medir
  -h, --help     esta ayuda

Sin modelo, usa OLLAMA_DEFAULT_MODEL del perfil activo y, si no existe,
qwen2.5-coder:1.5b.
EOF
}

# Modelo por defecto: variable del servicio → fallback.
default_model() {
    local m=""
    if [[ -f "$OVERRIDE" ]]; then
        m="$(sed -n 's/.*OLLAMA_DEFAULT_MODEL=\([^"]*\)".*/\1/p' "$OVERRIDE" | tail -n 1)"
    fi
    # El drop-in no guarda metadatos; usa el perfil que coincida con CONTEXT_LENGTH
    if [[ -z "$m" ]]; then
        local ctx_active
        ctx_active="$(systemctl show ollama.service -p Environment --value 2>/dev/null \
            | tr ' ' '\n' | sed -n 's/^OLLAMA_CONTEXT_LENGTH=//p')"
        shopt -s nullglob
        local f
        for f in "$REPO_ROOT"/profiles/*.env; do
            if [[ "$(sed -n 's/^OLLAMA_CONTEXT_LENGTH=//p' "$f")" == "$ctx_active" ]]; then
                m="$(sed -n 's/^OLLAMA_DEFAULT_MODEL=//p' "$f")"
                break
            fi
        done
        shopt -u nullglob
    fi
    printf '%s' "${m:-qwen2.5-coder:1.5b}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ctx)       CTX="${2:?falta el valor de --ctx}"; shift 2 ;;
        --tokens)    TOKENS="${2:?falta el valor de --tokens}"; shift 2 ;;
        --warm-only) COLD=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "opción desconocida: $1" ;;
        *)           MODEL="$1"; shift ;;
    esac
done

[[ -n "$MODEL" ]] || MODEL="$(default_model)"
curl -fsS --max-time 3 "$API/api/version" >/dev/null 2>&1 || die "la API no responde en $API"

printf 'modelo:      %s\n' "$MODEL"
printf 'num_ctx:     %s\n' "$CTX"
printf 'max_tokens:  %s\n' "$TOKENS"
printf 'api:         %s\n' "$API"
printf 'gpu:         %s\n\n' "$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | cut -d: -f3- | sed 's/^ *//' || echo 'desconocida')"

if [[ $COLD -eq 1 ]]; then
    printf 'descargando modelo de VRAM para medir en frío...\n'
    ollama stop "$MODEL" >/dev/null 2>&1 || true
    sleep 1
fi

MODEL="$MODEL" CTX="$CTX" TOKENS="$TOKENS" API="$API" COLD="$COLD" python3 - <<'PY'
import json, os, sys, time, urllib.request

model = os.environ["MODEL"]
ctx = int(os.environ["CTX"])
tokens = int(os.environ["TOKENS"])
api = os.environ["API"]

# Contexto representativo: código Lua real con un hueco a rellenar.
before = """local M = {}

local defaults = {
  enabled = true,
  debounce = 300,
}

function M.setup(opts)
  opts = vim.tbl_deep_extend('force', defaults, opts or {})
  if not opts.enabled then
    return
  end
"""

after = """  vim.api.nvim_create_autocmd('InsertEnter', {
    callback = function()
      M.attach()
    end,
  })
end

return M
"""


def run(label, cold):
    body = json.dumps({
        "model": model,
        "prompt": before,
        "suffix": after,
        "stream": True,
        "options": {
            "num_predict": tokens,
            "temperature": 0,
            "num_ctx": ctx,
        },
    }).encode()
    req = urllib.request.Request(
        f"{api}/api/generate", body, {"Content-Type": "application/json"}
    )
    t0 = time.time()
    ttft = None
    chunks = []
    done = {}
    try:
        with urllib.request.urlopen(req) as resp:
            for line in resp:
                line = line.strip()
                if not line:
                    continue
                data = json.loads(line)
                if ttft is None and data.get("response"):
                    ttft = time.time() - t0
                if data.get("response"):
                    chunks.append(data["response"])
                if data.get("done"):
                    done = data
    except Exception as exc:  # noqa: BLE001
        print(f"{label}: ERROR {exc}")
        return False

    total = time.time() - t0
    n = int(done.get("eval_count") or 0)
    dur = (done.get("eval_duration") or 1) / 1e9
    load = (done.get("load_duration") or 0) / 1e9
    tps = n / dur if dur else 0.0
    ttft_s = f"{ttft * 1000:7.0f} ms" if ttft is not None else "      —"
    print(f"{label}")
    print(f"  ttft    {ttft_s}")
    print(f"  total   {total:7.2f} s")
    print(f"  tokens  {n} ({tps:.1f} tok/s)")
    print(f"  carga   {load:.2f} s")
    preview = "".join(chunks).strip().replace("\n", " ⏎ ")
    print(f"  salida  {preview[:80]!r}")
    print()
    return True


if os.environ.get("COLD", "1") == "1":
    run("FRÍO (modelo recién cargado)", cold=True)
run("CALIENTE (segunda petición)", cold=False)
PY
