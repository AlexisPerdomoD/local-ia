# Local LLM Workstation

Guía para ejecutar modelos LLM locales en **Arch Linux + AMD Radeon RX 9060 XT de 16 GB**, con dos cargas de trabajo bien distintas:

1. **Agente de código** (OpenCode) sobre repositorios reales.
2. **Autocompletado inline en Neovim** (ghost text), donde lo que importa es la latencia en milisegundos.

> **Estado de esta guía:** 10 de noviembre de 2026, verificada contra Ollama 0.40.15 y minuet-ai.nvim v0.10.0. Los modelos, etiquetas de Ollama, paquetes de Arch y opciones de los runtimes cambian con frecuencia. Comprueba siempre las páginas oficiales enlazadas antes de automatizar instalaciones.

## Objetivo

Construir un entorno local que permita usar OpenCode sobre repositorios reales —especialmente proyectos Go, Python/FastAPI y TypeScript/Node— con capacidad para:

- Explorar un repositorio y localizar el código relevante.
- Razonar sobre cambios que afectan varios archivos.
- Editar código, ejecutar comandos y pruebas mediante herramientas de OpenCode.
- Mantener suficiente contexto durante una tarea.
- Ejecutar el modelo en la GPU AMD, evitando offloading a RAM salvo cuando se busque deliberadamente probar modelos mayores.
- Cambiar entre modelos y runtimes sin rehacer la instalación.

Y, sobre el mismo runtime, un segundo objetivo con requisitos opuestos:

- Completar código inline en Neovim con un modelo **FIM** (fill-in-the-middle) local.
- Latencia percibida por pulsación en el orden de **decenas de milisegundos**, no de segundos.
- Cero dependencia de servicios en la nube, claves de API o cuentas de terceros.

La primera fase usa **Ollama + Vulkan + OpenCode**. La segunda, opcional, añade **llama.cpp** para probar GGUF y ajustar con más precisión la inferencia.

El conflicto central de este repositorio es que ambas cargas piden configuraciones incompatibles: el agente quiere **contexto largo y un modelo grande**, el autocompletado quiere **contexto corto y un modelo caliente**. En vez de elegir una, el repo mantiene **perfiles**: conjuntos de variables de entorno que se aplican al servicio con un script (§14).

## Hardware de referencia

| Componente        | Referencia                                            |
| ----------------- | ----------------------------------------------------- |
| Sistema operativo | Arch Linux x86_64                                     |
| GPU               | AMD Radeon RX 9060 XT, 16 GB VRAM, RDNA 4 (`gfx1200`) |
| CPU               | AMD Ryzen 7 5800X                                     |
| Editor/agente     | OpenCode en terminal                                  |
| Runtime inicial   | Ollama con backend Vulkan                             |
| Runtime avanzado  | llama.cpp con Vulkan                                  |

La cantidad de RAM del sistema no está fijada en esta guía. Compruébala antes de probar offloading:

```bash
free -h
```

Para trabajar con modelos que excedan la VRAM, más RAM ayuda a cargarlos, pero **no convierte el offloading en una solución de alto rendimiento**. Las capas que terminan ejecutándose en CPU/RAM suelen reducir notablemente los tokens por segundo.

## Arquitectura

```text
OpenCode
   |
   | HTTP local
   v
Ollama API (127.0.0.1:11434)
   |
   v
Motor de inferencia de Ollama
   |
   v
Backend Vulkan
   |
   v
AMD Radeon RX 9060 XT (16 GB)
```

Ollama administra descargas, modelos, plantillas, parámetros y una API. llama.cpp permite trabajar directamente con GGUF y ajustar parámetros de inferencia y offloading. Comparten tecnología del ecosistema `llama.cpp`/`ggml` en muchas rutas, pero **no son intercambiables en cuanto a control ni configuración**.

OpenCode descubre automáticamente los modelos de Ollama cuando el servicio está escuchando en `127.0.0.1:11434`. No hace falta un plugin adicional ni un proveedor OpenAI personalizado para la instalación local básica.

Neovim, en cambio, no habla con Ollama por sí solo: necesita un cliente que envíe `prompt` + `suffix` al endpoint FIM y dibuje el ghost text. Aquí se usa **minuet-ai.nvim** (§16).

## Mapa del repositorio

```text
local-ia/
├── README.md                  ← este documento
├── install.sh                 ← instalación base + pasos opcionales
├── .gitignore
├── profiles/                  ← un archivo por perfil de servicio
│   ├── autocomplete.env       ← latencia mínima (Neovim inline)
│   ├── agent.env              ← contexto largo (OpenCode)
│   ├── hybrid.env             ← ambos a la vez
│   └── lean.env               ← diagnóstico / sin optimizaciones
├── scripts/
│   ├── ollama-profile.sh      ← list / current / show / apply
│   ├── healthcheck.sh         ← GPU + servicio + config + modelos
│   └── bench.sh               ← TTFT y tok/s de una petición FIM
└── nvim/
    └── minuet.lua             ← configuración de referencia para Neovim
```

## Inicio rápido

Desde este repositorio, en una máquina Arch ya instalada:

```bash
# 1. Estado actual del stack
./scripts/healthcheck.sh

# 2. Descargar el modelo de autocompletado (986 MB)
ollama pull qwen2.5-coder:1.5b

# 3. Aplicar el perfil de latencia mínima (pide sudo)
./scripts/ollama-profile.sh apply autocomplete

# 4. Medir
./scripts/bench.sh qwen2.5-coder:1.5b

# 5. Instalar la config de Neovim
./install.sh --neovim
```

En el editor, a partir de ahí: escribe en un archivo, espera el ghost text y acéptalo con `<C-a>`.

## Cómo se alterna entre agente y autocompletado

```bash
./scripts/ollama-profile.sh apply agent --preload   # trabajar con OpenCode
./scripts/ollama-profile.sh apply autocomplete      # volver a Neovim
./scripts/ollama-profile.sh current                 # ver qué hay activo
```

`apply` reescribe el drop-in de systemd, reinicia el servicio y espera a que la API responda. El modelo **no** se carga hasta la primera petición salvo que uses `--preload`, y cambiar el perfil descarga los modelos en memoria (ver §14).

---

# 1. Modelos recomendados para este equipo

La selección prioriza programación con agentes, tool calling, razonamiento y contexto, no solo autocompletado. Las cifras de memoria son orientativas y dependen del archivo exacto, tipo de caché KV, contexto, buffers del backend y VRAM que ya consuma el escritorio.

## Selección principal

| Prioridad | Modelo / variante                    | Uso recomendado                                                                    |                                    Tamaño aproximado |                          Contexto práctico inicial | Ruta               |
| --------- | ------------------------------------ | ---------------------------------------------------------------------------------- | ---------------------------------------------------: | -------------------------------------------------: | ------------------ |
| 1         | **GPT-OSS 20B** (`gpt-oss:20b`)      | Modelo inicial y baseline para OpenCode; razonamiento y uso de herramientas        | ~14 GB en Ollama; GGUF MXFP4 de referencia ~12.11 GB |                                                64K | Ollama + Vulkan    |
| 2         | **Gemma 4 12B** (`gemma4:12b`)       | Alternativa equilibrada; tareas con más archivos/contexto y margen de VRAM         |      ~7.7–8.0 GB en Ollama; Google QAT Q4_0 ~6.98 GB |                    64K; probar 128K si hay memoria | Ollama + Vulkan    |
| 3         | **Qwen3.8 27B** (`UD-Q3_K_XL`, GGUF) | Prueba de mayor capacidad/coding; cuantización de 3 bits y uso ajustado de memoria |                                    ~13.15 GB el GGUF | 64K requiere offloading potencial; revisar memoria | llama.cpp + Vulkan |

### 1.1 GPT-OSS 20B — primera instalación

```bash
ollama pull gpt-oss:20b
```

Es el punto de partida recomendado porque OpenAI indica que gpt-oss-20b está diseñado para ejecutarse en equipos con unos 16 GB de memoria. Incluye razonamiento y capacidades de uso de herramientas. La versión de Ollama ocupa aproximadamente 14 GB y anuncia una ventana máxima de 128K.

Una referencia de memoria calcula que el archivo GGUF MXFP4 de 12.11 GB requiere aproximadamente 12.8 GiB con 64K de contexto y caché Q8; es un cálculo orientativo, no un benchmark de tu RX 9060 XT. Deja margen variable para buffers, escritorio y otros procesos.

**Uso:** modelo de diario para tareas de análisis, refactorización, debugging y cambios multiarchivo razonables. Empieza con 64K y confirma que `ollama ps` indique `100% GPU`.

### 1.2 Gemma 4 12B — alternativa con margen

```bash
ollama pull gemma4:12b
```

Google describe Gemma 4 como una familia apta para programación, razonamiento y flujos agentic, con function calling nativo. La variante 12B tiene contexto máximo de 256K; el paquete de Ollama ocupa alrededor de 7.7–8.0 GB.

**Uso:** alternativa cuando GPT-OSS no resuelva bien una tarea o cuando convenga disponer de más espacio para contexto y memoria de GPU. No asumas que 256K será práctico en cualquier configuración: aumenta el contexto gradualmente y mide.

### 1.3 Qwen3.8 27B — prueba avanzada

El tag normal de Ollama `qwen3.8:27b` ocupa alrededor de 18 GB. **No descargues esa variante esperando que quepa íntegramente en 16 GB de VRAM.**

Para experimentar con tu GPU existe una cuantización GGUF de Unsloth:

- Repositorio: [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)
- Archivo: `Qwen3.8-27B-UD-Q3_K_XL.gguf`
- Tamaño publicado: aproximadamente 13.15 GB.

Es una cuantización comunitaria de 3 bits; no equivale a probar el checkpoint original a precisión completa. El tamaño del archivo tampoco incluye caché KV ni buffers de inferencia. La estimación publicada para 64K con caché Q8 ronda 14.4 GiB antes de buffers del runtime y consumo del escritorio; por tanto, es una carga muy ajustada para esta tarjeta. Para OpenCode intenta primero 64K (es la referencia recomendada por la integración de Ollama), pero cuenta con que quizá debas hacer offloading parcial a RAM. Si no resulta utilizable, reduce contexto para pruebas puntuales o vuelve a GPT-OSS/Gemma 4 para sesiones normales con OpenCode.

**Uso:** experimento para comparar calidad de código y razonamiento con GPT-OSS y Gemma 4. No es la configuración más simple ni la más holgada.

## Modelo adicional: Devstral Small 2

Devstral Small 2 24B es un candidato especialmente relevante para programación agentic: Mistral lo diseñó para explorar codebases, utilizar herramientas y editar varios archivos.

Sin embargo, la variante Q4 de Ollama ocupa unos 15 GB y no deja suficiente margen para caché KV y buffers en una GPU de 16 GB. Una ruta de menor cuantización publicada es `Q3_K_M` (~11.47 GB), que se estima en unos 13.4 GiB con caché Q8 a 32K, antes de contar todos los buffers/runtime.

Recomendación: dejarlo para una fase posterior con llama.cpp, empezar en 16K–32K y verificar la memoria. No lo usaría como instalación inicial ni asumiría que el contexto de 384K anunciado por Ollama pueda utilizarse íntegramente en esta tarjeta.

```bash
# No recomendado como primer modelo en una GPU de 16 GB:
# ollama pull devstral-small-2
```

## Modelos que no priorizaría en este hardware

- `qwen3.8:27b` Q4 de Ollama: el paquete anunciado ronda 18 GB, por encima de la VRAM disponible.
- `devstral-small-2` Q4 de Ollama: alrededor de 15 GB antes de contexto y buffers.
- Modelos de 30B+ en Q4 o modelos MoE cuyo total de pesos exceda claramente 16 GB: que tengan pocos parámetros activos **no** significa que todos los pesos quepan en VRAM.
- Modelos de cientos de miles de millones de parámetros: no son objetivos realistas para esta GPU.

## Importante sobre benchmarks

No se debe extrapolar un benchmark obtenido en una RTX de 24/48/96 GB a una RX 9060 XT. Tampoco hay que confundir una puntuación de generación de código con rendimiento de un agente editando un repositorio.

Las recomendaciones anteriores combinan fichas de modelos, tamaños de archivos y cálculos publicados para equipos de 16 GB. No prometen una cifra de tokens/s en tu equipo. Registra tus propias pruebas antes de decidir cuál es el mejor modelo para tu flujo de trabajo.

---

# 2. Preparar Arch Linux y Vulkan

## 2.1 Actualizar el sistema e instalar paquetes

En Arch, utiliza una actualización completa del sistema; evita actualizaciones parciales.

```bash
sudo pacman -Syu
sudo pacman -S --needed ollama-vulkan vulkan-radeon vulkan-tools
```

`ollama-vulkan` es el paquete de Arch para usar Ollama con Vulkan. `vulkan-radeon` proporciona el driver Vulkan de Mesa para GPU AMD y `vulkan-tools` incluye `vulkaninfo`.

No instales simultáneamente variantes diferentes de Ollama para ROCm y Vulkan. Para esta guía se elige Vulkan como primera ruta de trabajo en RDNA 4.

## 2.2 Verificar Vulkan

```bash
vulkaninfo --summary
```

Busca la Radeon RX 9060 XT en la lista de dispositivos. También puedes inspeccionar el driver del dispositivo PCI:

```bash
lspci -k | grep -A 3 -E 'VGA|Display|3D'
```

Si `vulkaninfo` no detecta la tarjeta, soluciona primero el driver Vulkan. No continúes con la instalación de modelos hasta que el dispositivo aparezca correctamente.

## 2.3 Permisos del servicio

El servicio de Ollama suele ejecutarse con el usuario de sistema `ollama`. Comprueba el usuario y los grupos:

```bash
id ollama
getent group render
getent group video
```

Si el usuario de servicio no pertenece a los grupos `render` y `video`, agrégalo:

```bash
sudo usermod -aG render,video ollama
```

Reinicia el servicio después de cambiar los grupos. Si esos grupos no existen en el sistema, revisa la configuración de dispositivos y permisos de tu instalación en vez de crear grupos a ciegas.

---

# 3. Instalar e iniciar Ollama

El paquete `ollama-vulkan` instala Ollama con soporte Vulkan.

```bash
sudo systemctl enable --now ollama.service
systemctl status ollama.service
ollama --version
```

El servicio expone por defecto la API local en:

```text
http://127.0.0.1:11434
```

Comprueba que responde:

```bash
curl -fsS http://127.0.0.1:11434/api/tags
```

Cuando `ollama.service` está activo, no ejecutes una segunda instancia de `ollama serve` en otra terminal.

## 3.1 Configuración inicial recomendada

Para OpenCode interesa un contexto de al menos 64K. Ollama puede comenzar con un contexto pequeño según la memoria disponible; no asumas que utilizará automáticamente el contexto máximo del modelo.

Crea un override de systemd:

```bash
sudo systemctl edit ollama.service
```

> Esta es la vía manual. La vía reproducible es `./scripts/ollama-profile.sh apply agent`, que escribe exactamente este contenido y reinicia el servicio (§14).

Añade:

```ini
[Service]
Environment="OLLAMA_VULKAN=1"
Environment="OLLAMA_CONTEXT_LENGTH=65536"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
```

Aplica los cambios:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

### Qué hace esta configuración

| Variable                      | Propósito                                                            |
| ----------------------------- | -------------------------------------------------------------------- |
| `OLLAMA_VULKAN=1`             | Habilita la detección del backend Vulkan.                            |
| `OLLAMA_CONTEXT_LENGTH=65536` | Define 64K como contexto predeterminado del servidor.                |
| `OLLAMA_NUM_PARALLEL=1`       | Limita solicitudes paralelas para contener el consumo de memoria.    |
| `OLLAMA_MAX_LOADED_MODELS=1`  | Evita mantener varios modelos cargados simultáneamente.              |
| `OLLAMA_FLASH_ATTENTION=1`    | Solicita Flash Attention cuando el backend/modelo lo admita.         |
| `OLLAMA_KV_CACHE_TYPE=q8_0`   | Reduce la memoria de la caché KV frente a F16, cuando es compatible. |

Estas opciones son una configuración inicial, no una garantía de que cada combinación de modelo/backend vaya a funcionar igual. Si aparecen errores Vulkan, fallos al cargar el modelo o resultados anómalos, elimina primero `OLLAMA_FLASH_ATTENTION` y `OLLAMA_KV_CACHE_TYPE`, reinicia Ollama y vuelve a probar. Conserva el contexto y el paralelismo bajo mientras diagnosticas.

Verifica las variables efectivas del servicio:

```bash
systemctl show ollama.service -p Environment
```

---

# 4. Descargar y probar los modelos base

## 4.1 Instalar el baseline

```bash
ollama pull gpt-oss:20b
```

Prueba la inferencia:

```bash
ollama run gpt-oss:20b
```

Escribe una consulta sencilla y sal con `Ctrl+D`.

## 4.2 Descargar la alternativa

```bash
ollama pull gemma4:12b
```

Prueba:

```bash
ollama run gemma4:12b
```

## 4.3 Revisar modelos instalados

```bash
ollama list
ollama show gpt-oss:20b
ollama show gemma4:12b
```

No descargues todos los modelos de una vez. Con 16 GB de VRAM es mejor cargar uno, medirlo, descargar el siguiente y comparar.

---

# 5. Comprobar que la GPU realmente está trabajando

Abre una terminal con:

```bash
watch -n 1 ollama ps
```

En otra terminal, carga el modelo y genera texto:

```bash
ollama run gpt-oss:20b
```

En `ollama ps`, revisa la columna `PROCESSOR`. Para un modelo que cabe por completo en VRAM, busca `100% GPU`.

También puedes observar los mensajes del servicio:

```bash
journalctl -u ollama.service -f
```

Instala `amdgpu_top` si quieres observar la actividad y la memoria de la GPU:

```bash
sudo pacman -S --needed amdgpu_top
amdgpu_top
```

### Interpretación

- `100% GPU`: los pesos del modelo están completamente en la GPU, según el reporte de Ollama.
- `CPU/GPU`: existe offloading o una distribución del modelo entre CPU y GPU.
- `100% CPU`: el modelo está ejecutándose sin aceleración GPU.

La columna `PROCESSOR` no es un benchmark de velocidad ni demuestra que el contexto completo esté consumiendo exactamente lo esperado. Mide también VRAM y tokens/s durante una tarea real.

---

# 6. Conectar Ollama con OpenCode

## 6.1 Instalar OpenCode (si todavía no está instalado)

```bash
curl -fsSL https://opencode.ai/install | bash
```

Comprueba:

```bash
opencode --version
```

## 6.2 Configurar el modelo predeterminado

OpenCode detecta automáticamente Ollama en `http://127.0.0.1:11434`. Para la conexión local básica no necesitas definir un proveedor personalizado.

Crea o edita:

```text
~/.config/opencode/opencode.json
```

Contenido mínimo para comenzar con GPT-OSS:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/gpt-oss:20b"
}
```

Si ya tienes configuración, no la sobrescribas: conserva tus propiedades actuales y añade o cambia únicamente `model`.

Para cambiar el modelo predeterminado a Gemma 4:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/gemma4:12b"
}
```

## 6.3 Seleccionar desde OpenCode

Desde un repositorio:

```bash
cd /ruta/a/tu/proyecto
opencode
```

Dentro de OpenCode ejecuta:

```text
/models
```

Selecciona un modelo del proveedor `ollama`. OpenCode actualiza la lista de modelos detectados en segundo plano.

También puedes iniciar el asistente de configuración de Ollama:

```bash
ollama launch opencode --model gpt-oss:20b
```

Para iniciar con configuración interactiva o generar la configuración sin arrancar inmediatamente el agente, consulta:

```bash
ollama launch opencode --help
```

## 6.4 Si Ollama escucha en otra dirección

Para un servidor Ollama remoto o un puerto diferente, agrega el proveedor en el formato actual de OpenCode:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/gpt-oss:20b",
  "providers": {
    "ollama": {
      "settings": {
        "baseURL": "http://127.0.0.1:11434/v1"
      }
    }
  }
}
```

En una instalación local normal, deja la dirección predeterminada y evita esta configuración adicional.

---

# 7. OpenCode: prácticas para agentes locales

Un modelo local tiene menos margen que los modelos hospedados de gran tamaño. El agente debe explorar el repositorio de forma incremental y recibir solo el contexto necesario.

## 7.1 Trabajar desde la raíz correcta

Inicia OpenCode en la raíz del repositorio para que las herramientas puedan descubrir archivos y comandos del proyecto:

```bash
cd ~/src/ownned
opencode
```

## 7.2 Dar tareas acotadas

En vez de pedir que reescriba una capa completa, define el comportamiento esperado, las restricciones arquitectónicas y las pruebas que deben continuar pasando.

Para Owned, conserva las convenciones reales del repositorio: Go idiomático, interfaces definidas por el consumidor, SQL explícito, límites transaccionales claros y pruebas relevantes. No asumas que el modelo conoce el historial de decisiones del proyecto; documenta las reglas importantes en instrucciones versionadas del repositorio.

## 7.3 Instrucciones persistentes del proyecto

OpenCode admite instrucciones y archivos de configuración por proyecto. Consulta su documentación actual antes de elegir entre `AGENTS.md`, reglas del proyecto o configuración de agentes:

- [OpenCode: Instructions](https://opencode.ai/v2/docs/instructions)
- [OpenCode: Agents](https://opencode.ai/v2/docs/agents)
- [OpenCode: Config](https://opencode.ai/v2/docs/config)

Para este repositorio de modelos locales, mantén las instrucciones de Owned en el propio repositorio Owned, no en el repositorio de configuración de LLMs.

## 7.4 Revisar antes de aceptar cambios

El agente puede ejecutar comandos y modificar archivos. Usa Git como límite de seguridad:

```bash
git status --short
git diff --check
git diff
```

No permitas que un agente local haga commits, cambie ramas, borre datos o ejecute migraciones destructivas sin revisar primero la operación.

---

# 8. Segunda fase: llama.cpp con Vulkan

Pasa a llama.cpp cuando necesites controlar el GGUF exacto, el número de capas cargadas en GPU, la caché KV y el offloading. No necesitas instalarlo para comenzar con Ollama.

## 8.1 Instalar dependencias de compilación

```bash
sudo pacman -S --needed base-devel cmake git vulkan-radeon vulkan-headers vulkan-icd-loader shaderc spirv-headers
```

## 8.2 Clonar y compilar

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j"$(nproc)"
```

Verifica el servidor:

```bash
./build/bin/llama-server --help
```

Comprueba que el backend Vulkan esté disponible. La salida del servidor al cargar el modelo debe identificar el dispositivo AMD.

## 8.3 Descargar la cuantización GGUF de Qwen3.8

Instala el cliente Hugging Face CLI en un entorno aislado, por ejemplo:

```bash
uv tool install huggingface_hub
```

Descarga el archivo:

```bash
mkdir -p ~/models/qwen3.8
hf download unsloth/Qwen3.8-27B-GGUF \
  Qwen3.8-27B-UD-Q3_K_XL.gguf \
  --local-dir ~/models/qwen3.8
```

Comprueba que el tamaño descargado coincida con el archivo esperado. Mantén los modelos fuera del repositorio Git: los GGUF pesan varios GB.

## 8.4 Ejecutar llama-server

Para integrarlo con OpenCode, intenta 64K porque la guía de integración recomienda al menos ese contexto. La cuantización Q3 de Qwen3.8 ya consume una parte importante de la VRAM; 64K puede requerir offloading parcial y ser lento en 16 GB. Si solo cabe a 16K/32K, úsalo como experimento del runtime/modelo, no como configuración diaria de OpenCode.

```bash
./build/bin/llama-server \
  -m ~/models/qwen3.8/Qwen3.8-27B-UD-Q3_K_XL.gguf \
  --alias qwen3.8-q3 \
  --host 127.0.0.1 \
  --port 8080 \
  -c 65536 \
  -ngl all \
  -fa on \
  -ctk q8_0 \
  -ctv q8_0
```

Si falla por memoria, reduce `-c`, reduce `-ngl` para dejar capas en CPU o prueba una cuantización más pequeña. El offloading a CPU puede funcionar, pero reduce velocidad. Comprueba las opciones disponibles en la versión que compilaste:

```bash
./build/bin/llama-server --help
```

No asumas que una línea de comandos publicada para otra versión de llama.cpp seguirá siendo válida sin cambios.

## 8.5 Configurar OpenCode contra llama.cpp

Para utilizar llama.cpp en lugar de Ollama, crea una configuración separada o cambia temporalmente el proveedor/modelo en tu configuración de OpenCode:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llama-local/qwen3.8-q3",
  "providers": {
    "llama-local": {
      "name": "llama.cpp local",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {
        "qwen3.8-q3": {
          "modelID": "qwen3.8-q3",
          "name": "Qwen3.8 27B Q3",
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          },
          "limit": {
            "context": 65536,
            "output": 4096
          }
        }
      }
    }
  }
}
```

El `modelID` debe coincidir con `--alias`. El límite de contexto en OpenCode debe reflejar el contexto real con que se inició `llama-server`, no el máximo que anuncia la ficha del modelo. Si el modelo solo se mantiene estable con 16K/32K, cambia ambos valores de forma consistente, sabiendo que queda por debajo de los 64K recomendados para agentes de código en la integración de Ollama.

**Nota:** declarar `tools: true` informa a OpenCode de la capacidad esperada, pero no garantiza que cualquier modelo/plantilla GGUF implemente correctamente el tool calling. Valida que el modelo genere llamadas estructuradas y que OpenCode ejecute realmente las herramientas antes de usarlo para cambios autónomos.

---

# 9. Pruebas comparables en Owned

La mejor manera de elegir el modelo es utilizar las mismas tareas sobre el mismo commit del repositorio.

## 9.1 Preparar un benchmark manual

Antes de cada ejecución:

```bash
git status --short
git rev-parse HEAD
ollama ps
```

Registra:

- Modelo y tag/quant exactos.
- Versión de Ollama o commit de llama.cpp.
- Contexto configurado.
- Tipo de caché KV.
- Uso de VRAM y si hay offloading.
- Tokens/s de generación si el runtime los reporta.
- Duración y resultado funcional de la tarea.
- Si llamó correctamente a herramientas, ejecutó pruebas y corrigió errores.

## 9.2 Casos de prueba sugeridos

Ejecuta las mismas tareas con cada modelo. Empieza con una tarea de solo lectura y deja las modificaciones para después.

1. **Navegación:** pide localizar el flujo de creación de grupos y describir el recorrido HTTP → caso de uso → repositorios → transacción, citando los archivos y símbolos reales.
2. **Cambio acotado:** pide implementar una validación concreta en un caso de uso, añadiendo o actualizando sus pruebas, sin cambiar contratos ajenos a la tarea.
3. **Debugging:** proporciona un error de test y pide reproducirlo, identificar la causa, corregirlo y volver a ejecutar las pruebas relevantes.
4. **Cambio multiarchivo:** pide modificar un comportamiento que afecte DTO, caso de uso, repositorio y handler, respetando las dependencias existentes.

Un modelo aprueba una tarea si mantiene los requisitos, inspecciona los archivos correctos, genera un diff pequeño y coherente, usa las herramientas correctamente y deja pasar las pruebas relevantes. Una respuesta convincente sin ejecutar/verificar el código no cuenta como éxito completo.

## 9.3 Guardar resultados

Puedes conservar una tabla CSV o Markdown fuera de los pesos del modelo, por ejemplo:

```text
benchmarks/
  2026-10-30-owned-baseline.md
  results.csv
```

No subas al repositorio los pesos de los modelos ni archivos de caché.

---

# 10. Diagnóstico y solución de problemas

## Ollama responde, pero la GPU no se utiliza

```bash
vulkaninfo --summary
id ollama
systemctl show ollama.service -p Environment
journalctl -u ollama.service -b | grep -Ei 'vulkan|gpu|error|memory'
```

Comprueba que:

- Está instalado `ollama-vulkan`, no solamente el paquete CPU.
- Está instalado `vulkan-radeon`.
- Vulkan enumera la RX 9060 XT.
- El usuario de servicio tiene los permisos necesarios para acceder a `/dev/dri`.
- `OLLAMA_VULKAN=1` está presente y el servicio se reinició.

## El modelo utiliza CPU y GPU

El modelo o su caché no caben por completo en la VRAM. Reduce el contexto, descarga modelos que no uses y cierra aplicaciones que consuman VRAM. Si continúa el offloading, elige una cuantización más pequeña.

## OpenCode no muestra el modelo

```bash
curl -fsS http://127.0.0.1:11434/api/tags
curl -fsS http://127.0.0.1:11434/api/show -d '{"name":"gpt-oss:20b"}'
```

Después:

- Verifica que Ollama está activo.
- Verifica que el modelo ya fue descargado.
- Abre `/models` y espera la actualización del inventario.
- Comprueba que OpenCode esté usando el proveedor `ollama` y el ID `ollama/nombre-del-modelo`.
- Revisa que el modelo tenga capacidad `completion`; los modelos de solo embeddings no aparecen.

## El agente pierde archivos o contexto

- Confirma que Ollama arrancó con el contexto esperado.
- Comprueba `ollama ps` y la configuración `OLLAMA_CONTEXT_LENGTH`.
- Verifica el límite `context` en el proveedor personalizado cuando uses llama.cpp.
- Reduce el tamaño de la tarea y pide al agente que inspeccione archivos progresivamente.
- No pongas un límite mayor en OpenCode que el que realmente acepta el servidor.

## Error de memoria (OOM) o el escritorio se vuelve lento

1. Detén el modelo: `ollama stop gpt-oss:20b`.
2. Reduce el contexto.
3. Desactiva Flash Attention o caché Q8 temporalmente si el log indica incompatibilidad.
4. Cierra aplicaciones que consumen VRAM.
5. Usa Gemma 4 12B o un modelo con menor cuantización.

## Reiniciar y detener

```bash
sudo systemctl restart ollama.service
sudo systemctl stop ollama.service
sudo systemctl start ollama.service
```

---

# 11. Estructura de este repositorio

La estructura real, que ya incluye los scripts de perfiles y benchmarks:

```text
local-ia/
├── README.md
├── install.sh              # paquetes + servicio + pasos opcionales
├── .gitignore
├── profiles/
│   ├── autocomplete.env    # Neovim inline: ctx 4K, 2 modelos, keep_alive=5m
│   ├── agent.env           # OpenCode: ctx 64K, 1 modelo
│   ├── hybrid.env          # ambos: ctx 32K, 2 modelos, keep_alive=30m
│   └── lean.env            # diagnóstico: sin flash-attn ni KV quantizado
├── scripts/
│   ├── ollama-profile.sh   # list | current | show | apply [--dry-run|--preload]
│   ├── healthcheck.sh      # 7 bloques de verificación, exit 1 si falla algo
│   └── bench.sh            # TTFT frío/caliente + tok/s de una petición FIM
├── nvim/
│   └── minuet.lua          # spec de lazy.nvim lista para copiar
└── benchmarks/             # (opcional) resultados fechados
```

Los pesos de los modelos **nunca** viven en el repo: con el paquete de Arch están en `/var/lib/ollama`, propiedad del usuario `ollama`.

## Principios para los scripts

- Deben comprobar que el sistema es Arch Linux antes de ejecutar `pacman`.
- Usar `set -Eeuo pipefail` y mensajes de error claros.
- Preferir `pacman -S --needed` para que las instalaciones sean repetibles.
- No sobrescribir `opencode.json` ni overrides de systemd del usuario sin copia de seguridad o confirmación.
- No descargar modelos por defecto sin que el usuario elija; pueden ocupar decenas de GB.
- No ejecutar `sudo` dentro de todo el script si solo algunas operaciones lo requieren.
- Mantener los pesos en `~/.ollama` o `~/models`, nunca dentro del repositorio.
- Registrar versiones, cuantizaciones, fecha y hardware al generar benchmarks.
- Ofrecer una opción `--dry-run` para operaciones de instalación/configuración.

## `.gitignore` sugerido

```gitignore
# Model weights and large local artifacts
models/
*.gguf
*.safetensors
*.bin
*.pt
*.pth

# Runtime and benchmark output
logs/
*.log
benchmarks/raw/

# Local secrets and personal configuration
.env
.env.*
!.env.example
config/opencode/opencode.local.json
```

---

# 12. Secuencia de implementación sugerida

Para mantener el proyecto simple y verificable:

1. **Primero:** terminar la instalación manual de Vulkan, Ollama y OpenCode siguiendo las secciones 2–6.
2. **Segundo:** confirmar que GPT-OSS 20B corre con `100% GPU` y 64K de contexto.
3. **Tercero:** ejecutar los casos de prueba sobre Owned y guardar el baseline.
4. **Cuarto:** probar Gemma 4 12B con la misma metodología.
5. **Quinto:** añadir llama.cpp y evaluar Qwen3.8 Q3 como experimento avanzado.
6. **Sexto:** convertir únicamente los pasos que ya probaste manualmente en scripts idempotentes.

No automatices una configuración que todavía no has validado en tu propia máquina. El README debe reflejar el comportamiento medido, no únicamente las opciones que existen en los manuales.

---

# 13. Referencias y material de estudio

## Arch Linux y GPU AMD

- [ArchWiki — Ollama](https://wiki.archlinux.org/title/Ollama): instalación de paquetes CPU, Vulkan, CUDA y ROCm; servicio systemd.
- [Arch Linux — `ollama-vulkan`](https://archlinux.org/packages/extra/x86_64/ollama-vulkan/): paquete para inferencia Vulkan.
- [Arch Linux — `vulkan-radeon`](https://archlinux.org/packages/extra/x86_64/vulkan-radeon/): driver Vulkan de AMD.
- [AMD ROCm — System requirements](https://rocm.docs.amd.com/projects/install-on-linux/en/develop/reference/system-requirements.html): matriz de GPU/arquitectura. La RX 9060 XT aparece como RDNA 4 / `gfx1200`; esta guía empieza por Vulkan, no por ROCm.

## Ollama

- [Ollama — GPU support](https://docs.ollama.com/gpu): backends, drivers y selección de GPU.
- [Ollama — Context length](https://docs.ollama.com/context-length): contexto y consumo de memoria.
- [Ollama — Modelfile](https://docs.ollama.com/modelfile): crear perfiles con parámetros como `num_ctx`.
- [Ollama — OpenCode integration](https://github.com/ollama/ollama/blob/main/docs/integrations/opencode.mdx): integración oficial y `ollama launch opencode`.
- [Ollama library — GPT-OSS](https://ollama.com/library/gpt-oss).
- [Ollama library — Gemma 4 12B](https://ollama.com/library/gemma4:12b).
- [Ollama library — Qwen3.8](https://ollama.com/library/qwen3.8).
- [Ollama library — Devstral Small 2](https://ollama.com/library/devstral-small-2).

## OpenCode

- [OpenCode — Models](https://opencode.ai/v2/docs/models/): IDs de modelo, selección, descubrimiento local y proveedores.
- [OpenCode — Providers](https://opencode.ai/v2/docs/providers): configuración de proveedores.
- [OpenCode — Config](https://opencode.ai/v2/docs/config): configuración global y por proyecto.
- [OpenCode — Instructions](https://opencode.ai/v2/docs/instructions): instrucciones para proyectos.
- [OpenCode — Agents](https://opencode.ai/v2/docs/agents): agentes y delegación.

## llama.cpp y cuantización

- [llama.cpp — GitHub](https://github.com/ggml-org/llama.cpp): runtime, servidor y documentación.
- [llama.cpp — Build](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md): compilación y backend Vulkan.
- [Unsloth — Qwen3.8 27B GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF): variantes GGUF y cuantizaciones.
- [OpenAI — Introducing gpt-oss](https://openai.com/index/introducing-gpt-oss/): características y memoria de referencia del modelo.
- [Google — Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4): capacidades, contexto, arquitectura y licencia.
- [Mistral — Devstral 2](https://mistral.ai/news/devstral-2-vibe-cli/): modelo de programación agentic y variante Small 2.

## Comparación de modelos en 16 GB

- [16GB VRAM: guía de tamaños, caché KV y cuantizaciones](https://blog.laozhang.ai/en/posts/best-local-coding-llm-16gb-vram): contiene cálculos orientativos para GPT-OSS 20B, Qwen3.8 27B Q3, Gemma 4 12B y Devstral Small 2 Q3. Úsala como referencia secundaria, no como garantía de rendimiento en RX 9060 XT.
- [whatmodel.sh — modelos locales para GPU de 16 GB](https://whatmodel.sh/llm/for/16gb-vram-local): índice de modelos y evaluaciones; revisa siempre los archivos exactos y las fuentes de cada benchmark.

---

# 14. Perfiles de configuración y scripts

## 14.1 Qué es un perfil aquí

Un **perfil** es un archivo `profiles/<nombre>.env` con variables de entorno de Ollama. `scripts/ollama-profile.sh apply <nombre>` traduce ese archivo a un drop-in de systemd y reinicia el servicio.

```text
profiles/autocomplete.env
        │
        │  ollama-profile.sh apply autocomplete
        v
/etc/systemd/system/ollama.service.d/override.conf
        │
        │  systemctl daemon-reload && systemctl restart ollama.service
        v
ollama serve (con las variables aplicadas)
```

Conviene perfilar porque las dos cargas piden cosas opuestas:

| Recurso      | Agente (OpenCode)     | Autocompletado (Neovim)  |
| ------------ | --------------------- | ------------------------ |
| Contexto     | 32K–64K               | 4K                       |
| Modelo       | 12–20 GB (MoE grande) | ~1 GB (1.5B)             |
| Latencia     | Segundos aceptables   | Decenas de ms            |
| Paralelismo  | 1                     | 1–2                      |
| Keep alive   | 30 min                | 5 min (on-demand)        |

No hay un valor único que sirva para ambos. Forzar 64K de contexto para completar dos líneas desperdicia KV cache y hace la petición más lenta; forzar 4K para un agente rompe tareas multi-archivo.

## 14.2 Los cuatro perfiles incluidos

| Perfil         | Modelo por defecto   | ctx    | Paralelo | Modelos | keep_alive | Para qué |
| -------------- | -------------------- | ------ | -------- | ------- | ---------- | -------- |
| `autocomplete` | `qwen2.5-coder:1.5b` | 4 096  | 2        | 2       | `5m`       | Ghost text. Latencia mínima, on-demand |
| `agent`        | `gpt-oss:20b`        | 65 536 | 1        | 1       | `30m`      | OpenCode con contexto largo |
| `hybrid`       | `qwen2.5-coder:1.5b` | 32 768 | 2        | 2       | `30m`      | Neovim + OpenCode en la misma sesión |
| `lean`         | `qwen2.5-coder:1.5b` | 4 096  | 1        | 1       | `10m`      | Diagnóstico: sin flash-attn ni KV cuantizada |

Los tres primeros llevan `OLLAMA_FLASH_ATTENTION=1` y `OLLAMA_KV_CACHE_TYPE=q8_0`; `lean` los omite a propósito para descartar la optimización como causa de un fallo.

Cada archivo puede llevar además metadatos que **no** se escriben en systemd:

```bash
OLLAMA_DEFAULT_MODEL=qwen2.5-coder:1.5b
```

Ese valor lo consumen `apply --preload`, `bench.sh` y `install.sh` para saber qué cargar.

## 14.3 Uso del script

```bash
./scripts/ollama-profile.sh list
./scripts/ollama-profile.sh current
./scripts/ollama-profile.sh show autocomplete
./scripts/ollama-profile.sh apply autocomplete --dry-run
sudo ./scripts/ollama-profile.sh apply autocomplete --preload
```

| Comando | Qué hace |
| ------- | -------- |
| `list` | Nombre, modelo y primera línea de comentario de cada perfil |
| `current` | Servicio activo, contenido del drop-in y variables **efectivas** (`systemctl show -p Environment`), más `ollama ps` |
| `show` | Imprime el perfil tal cual |
| `apply` | Backup del drop-in, escribe el nuevo, `daemon-reload`, `restart`, espera la API |
| `apply --dry-run` | Muestra el drop-in resultante sin tocar nada |
| `apply --no-restart` | Escribe pero no reinicia (los cambios no están activos) |
| `apply --preload` | Además carga el `OLLAMA_DEFAULT_MODEL` en VRAM |

`apply` hace **backup** antes de escribir:

```text
/etc/systemd/system/ollama.service.d/override.conf.bak.20261110-124110
```

Revertir es restaurar ese archivo y ejecutar `sudo systemctl daemon-reload && sudo systemctl restart ollama.service`.

## 14.4 Crear un perfil nuevo

```bash
cp profiles/autocomplete.env profiles/mi-perfil.env
$EDITOR profiles/mi-perfil.env     # cambia las variables y la cabecera
./scripts/ollama-profile.sh list    # aparece automáticamente
./scripts/ollama-profile.sh apply mi-perfil --dry-run
```

No hay registro central: el script descubre todo lo que haya en `profiles/*.env`.

## 14.5 Detalle importante: cambiar el contexto recarga el modelo

`OLLAMA_CONTEXT_LENGTH` no es un parámetro que se pueda cambiar en caliente. Al modificarlo, la siguiente petición provoca una **recarga completa** del modelo. Medido en este equipo con `qwen2.5-coder:1.5b`:

```text
petición con num_ctx=4096   →  caliente, TTFT 9 ms
petición con num_ctx=65536  →  recarga, TTFT 1354 ms, load_duration 1.19 s
```

Por eso los perfiles fijan el contexto **por sesión de trabajo** y no se cambia por petición. Si vas a alternar mucho entre agente y autocompletado, usa `hybrid` (32K) en lugar de saltar entre 4K y 64K.

## 14.6 Requisito de sudo

Escribir en `/etc/systemd/system` y reiniciar el servicio exige root. El script llama a `sudo -v` al principio de `apply` (no en `list`, `current`, `show` ni `--dry-run`), así que la contraseña se pide una sola vez por ejecución.

Si prefieres no dar sudo a un script, `apply --dry-run` genera el contenido exacto y puedes copiarlo a mano:

```bash
sudo systemctl edit ollama.service
```

---

# 15. Referencia completa de parámetros de Ollama

Esta sección está verificada contra **Ollama 0.40.15** (`ollama serve --help`) en Arch Linux. Los nombres son estables, pero los valores por defecto pueden cambiar entre versiones: comprueba la ayuda de tu binario con `ollama serve --help`.

Hay **cuatro niveles** de configuración y conviene no confundirlos:

| Nivel | Dónde se define | Alcance | Ejemplo |
| ----- | --------------- | ------- | ------- |
| 1. Entorno del servidor | systemd / `ollama serve` | Todo el proceso | `OLLAMA_CONTEXT_LENGTH` |
| 2. Modelfile | `ollama create` | Un modelo concreto | `PARAMETER num_ctx 4096` |
| 3. Petición HTTP | `options` en `/api/*` | Una llamada | `"num_predict": 64` |
| 4. `keep_alive` | Petición o servidor | Tiempo en memoria | `-1` |

## 15.1 Variables de entorno del servidor

### Red y servicio

| Variable | Default | Qué controla | Cuándo tocarla |
| -------- | ------- | ------------ | -------------- |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Dirección/puerto de escucha | Exponer en LAN (`0.0.0.0:11434`) sólo con firewall y auth delante |
| `OLLAMA_ORIGINS` | sólo `localhost` | Orígenes permitidos para CORS | Cliente web en otro host |
| `OLLAMA_MODELS` | `~/.ollama/models` | Directorio de pesos | Aquí: `/var/lib/ollama` (servicio de sistema) |
| `OLLAMA_DEBUG` | `0` | Log verboso | Diagnosticar cargas y shaders |
| `OLLAMA_DEBUG_LOG_REQUESTS` | `0` | Loguea peticiones y respuestas completas | Sólo en depuración: **incluye tu código** |
| `OLLAMA_NO_CLOUD` | `0` | Desactiva inferencia remota y web search | `1` si quieres garantía de que nada sale del equipo |
| `OLLAMA_NOPRUNE` | `0` | No borra blobs huérfanos al arrancar | `1` sólo si gestionas blobs a mano |
| `OLLAMA_MAX_TRANSFER_STREAMS` | `4` | Descargas paralelas de `pull`/`push` | Subirlo acelera pulls en conexiones rápidas |

### Memoria, contexto y scheduling

| Variable | Default | Qué controla | Cuándo tocarla |
| -------- | ------- | ------------ | -------------- |
| `OLLAMA_CONTEXT_LENGTH` | según VRAM (4K/32K/256K) | Contexto por defecto si la petición no lo fija | Fijarlo explícitamente; es el parámetro que más afecta a VRAM y velocidad |
| `OLLAMA_NUM_PARALLEL` | auto (1 o 4 según VRAM) | Peticiones simultáneas por modelo | `1` para latencia predecible; cada slot extra multiplica la KV cache |
| `OLLAMA_MAX_LOADED_MODELS` | 3 × nº de GPUs | Modelos distintos en memoria a la vez | `2` si quieres coder + chat sin expulsiones |
| `OLLAMA_MAX_QUEUE` | `512` | Peticiones en cola antes de rechazar | Bajar en equipos pequeños |
| `OLLAMA_KEEP_ALIVE` | `5m` | Tiempo que el modelo permanece cargado | `-1` para no pagar nunca un cold start; `0` para descargar al terminar |
| `OLLAMA_LOAD_TIMEOUT` | `5m` | Tiempo máximo permitido para cargar | Subir si cargas modelos de 30B+ desde disco lento |
| `OLLAMA_GPU_OVERHEAD` | `0` | VRAM reservada por GPU (bytes) | Reservar margen si el driver compite con el escritorio |
| `OLLAMA_SCHED_SPREAD` | `0` | Reparte el modelo entre todas las GPUs | Multi-GPU, no en una sola tarjeta |
| `OLLAMA_IGPU_ENABLE` | `0` | Habilita iGPU | Portátiles híbridos |
| `OLLAMA_LLM_LIBRARY` | auto | Fuerza una librería de inferencia | Depurar selección de backend |

### Calidad y matemática

| Variable | Default | Qué controla | Cuándo tocarla |
| -------- | ------- | ------------ | -------------- |
| `OLLAMA_FLASH_ATTENTION` | según versión | Flash Attention (menos VRAM en contextos largos) | `1` casi siempre; `0` si ves resultados corruptos |
| `OLLAMA_KV_CACHE_TYPE` | `f16` | Cuantización de la KV cache: `f16`, `q8_0`, `q4_0` | `q8_0` reduce ~50% la cache con pérdida mínima; `q4_0` sólo si falta VRAM |
| `LLAMA_ARG_FIT` | `on` | Deja que llama.cpp ajuste automáticamente opciones de memoria | `off` para control manual exacto |
| `LLAMA_ARG_FIT_TARGET` | según build | Margen libre de VRAM objetivo (MiB) | Subirlo si el driver sufre OOM |

### Backend específico de Arch

| Variable | Valor | Qué controla |
| -------- | ----- | ------------ |
| `OLLAMA_VULKAN` | `1` | Activa el backend Vulkan del paquete `ollama-vulkan`. Sin esto, el binario usa CPU o ROCm si está disponible |

No aparece en `ollama serve --help` porque la detecta la build empaquetada, pero es la que hace que la RX 9060 XT aparezca como `100% GPU` en `ollama ps`.

## 15.2 Opciones por petición (`options`)

Se envían en el cuerpo de `/api/generate` o `/api/chat`. Son **por llamada**: no requieren reiniciar el servicio (salvo las que fuerzan recarga de contexto, como `num_ctx`).

### Longitud y muestreo

| Parámetro | Default | Efecto | Nota práctica |
| --------- | ------- | ------ | ------------- |
| `num_predict` | `-1` | Tokens máximos a generar | Para inline: 48–96. Más alto = más latencia |
| `num_keep` | `4` | Tokens iniciales que se conservan al truncar | Rara vez se toca |
| `temperature` | `0.8` | Aleatoriedad | `0` para completado determinista |
| `top_k` | `40` | Recorta a los K tokens más probables | `40` está bien; `1` = greedy |
| `top_p` | `0.9` | Muestreo nucleus | `0.9`–`0.95` |
| `min_p` | `0.0` | Descarta tokens con probabilidad < min_p × p_max | Alternativa moderna a `top_p` |
| `typical_p` | `1.0` | Muestreo típico | Dejar en 1 salvo experiments |
| `tfs_z` | `1.0` | Tail-free sampling | Obsoleto en la práctica |
| `repeat_penalty` | `1.1` | Penaliza repetición | `1.0` para código; `1.1` si repite líneas |
| `repeat_last_n` | `64` | Ventana para la penalización | `64`–`256` |
| `presence_penalty` | `0.0` | Penaliza tokens ya presentes | FIM suele ir a `0` |
| `frequency_penalty` | `0.0` | Penaliza por frecuencia | FIM suele ir a `0` |
| `penalize_newline` | `true` | Penaliza `\n` | **`false` para código**: si no, evita saltos de línea |
| `seed` | aleatorio | Semilla | Fijarla para benchmarks reproducibles |
| `stop` | `[]` | Cadenas que cortan la generación | Con plantilla FIM no hace falta: el modelo corta en `<|fim_middle|>` |

### Memoria y ejecución

| Parámetro | Default | Efecto | Nota práctica |
| --------- | ------- | ------ | ------------- |
| `num_ctx` | el del servidor | Ventana de contexto | **Forzarlo recarga el modelo**. En este repo se fija por perfil |
| `num_batch` | `512` | Tokens por lote en el prefill | Subir acelera prompts largos si sobra VRAM |
| `num_gpu` | auto | Capas a offload a GPU | `999` fuerza todas; bajar si hay OOM |
| `main_gpu` | `0` | GPU principal | Multi-GPU |
| `low_vram` | `false` | Modo de VRAM reducida | Sólo si no cabe de otra forma: muy lento |
| `f16_kv` | `true` | KV cache en fp16 | `false` usa el tipo de `OLLAMA_KV_CACHE_TYPE` |
| `use_mmap` | `true` | Mapea pesos desde disco | `false` acelera cargas repetidas usando más RAM |
| `use_mlock` | `false` | Bloquea pesos en RAM | Evita swap a costa de RAM |
| `num_thread` | núcleos físicos | Hilos de CPU | Irrelevante si todo está en GPU |
| `numa` | `false` | Optimización NUMA | Servidores multi-socket |
| `vocab_only` | `false` | Carga sólo el vocabulario | Depuración |

### `mirostat` (muestreo adaptativo)

| Parámetro | Default | Efecto |
| --------- | ------- | ------ |
| `mirostat` | `0` | `0` desactivado, `1` Mirostat, `2` Mirostat 2.0 |
| `mirostat_tau` | `5.0` | Perplejidad objetivo (menor = más conservador) |
| `mirostat_eta` | `0.1` | Tasa de aprendizaje del control |

Para código, `temperature=0` da resultados más estables que Mirostat. Mirostat es útil en texto libre donde quieres evitar bucles sin bajar la temperatura.

## 15.3 Campos de la petición HTTP

`POST /api/generate`:

| Campo | Tipo | Para qué |
| ----- | ---- | -------- |
| `model` | string | Nombre exacto, p. ej. `qwen2.5-coder:1.5b` |
| `prompt` | string | Texto antes del cursor |
| `suffix` | string | **Texto después del cursor** (FIM). Sólo se usa si la plantilla del modelo tiene `{{ .Suffix }}` |
| `system` | string | System prompt (ignorado por plantillas FIM puras) |
| `template` | string | Sobrescribe la plantilla del modelo para esta llamada |
| `images` | array | Imágenes en base64 (modelos multimodales) |
| `format` | `json` o schema | Salida estructurada |
| `options` | objeto | Todo lo de §15.2 |
| `stream` | bool | `true` devuelve NDJSON token a token (lo que usa el ghost text) |
| `raw` | bool | `true` no aplica plantilla: tú mandas los marcadores FIM a mano |
| `keep_alive` | string/número | `"5m"`, `"30m"`, `-1` (nunca descargar), `0` (descargar al acabar) |
| `context` | array | Contexto devuelto por una llamada anterior (API legacy, no usar con FIM) |

Verificar que un modelo soporta FIM:

```bash
curl -s http://127.0.0.1:11434/api/show -d '{"model":"qwen2.5-coder:1.5b"}' \
  | jq -r '.capabilities, .template' | head -20
```

Debe aparecer `insert` en `capabilities` y una plantilla con `<|fim_prefix|>`, `<|fim_suffix|>` y `<|fim_middle|>`. Si no, ese modelo no sirve para completado inline.

Prueba directa de FIM (la misma forma que usa minuet):

```bash
curl -s http://127.0.0.1:11434/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen2.5-coder:1.5b",
    "prompt": "def suma(a, b):\n    ",
    "suffix": "\n\nprint(suma(1, 2))",
    "max_tokens": 32,
    "temperature": 0
  }' | jq -r '.choices[0].text'
```

## 15.4 Modelfile

Un Modelfile crea una variante de modelo con parámetros fijos. Útil cuando quieres un "modelo" que ya lleve tu configuración sin depender del entorno del servicio.

```dockerfile
FROM qwen2.5-coder:1.5b

# Contexto por defecto de este modelo
PARAMETER num_ctx 4096
PARAMETER temperature 0
PARAMETER num_predict 64
PARAMETER stop "<|fim_middle|>"

# Plantilla (normalmente NO se toca: la del modelo ya es FIM)
# TEMPLATE """..."""
```

```bash
ollama create coder-inline -f Modelfile
ollama run coder-inline
```

| Instrucción | Función |
| ----------- | ------- |
| `FROM` | Modelo base o ruta a GGUF/safetensors |
| `PARAMETER` | Cualquier opción de §15.2 como valor por defecto |
| `TEMPLATE` | Plantilla de prompt completa |
| `SYSTEM` | System prompt por defecto |
| `ADAPTER` | LoRA/adaptador |
| `MESSAGE` | Mensajes de few-shot para `ollama run` |
| `LICENSE` | Texto de licencia |

Los `PARAMETER` del Modelfile son **defaults**: una petición puede sobrescribirlos con `options`. La excepción práctica es `num_ctx`, que sigue forzando recarga si cambia respecto al valor cargado.

## 15.5 Qué respeta la capa OpenAI-compatible

Minuet habla con `http://127.0.0.1:11434/v1/completions`. Esa capa implementa el subconjunto OpenAI:

| Se respeta | No se respeta (se ignora) |
| ---------- | ------------------------- |
| `model`, `prompt`, `suffix`, `stream` | `num_ctx`, `num_batch`, `num_gpu`, `low_vram` |
| `max_tokens` → `num_predict` | `num_thread`, `use_mmap`, `use_mlock` |
| `temperature`, `top_p`, `stop`, `seed` | `mirostat*`, `tfs_z`, `typical_p` |
| `presence_penalty`, `frequency_penalty` | `numa`, `vocab_only`, `main_gpu` |

Consecuencia práctica: **el contexto para el autocompletado se fija en el servidor** (`OLLAMA_CONTEXT_LENGTH`, vía perfil), no en el cliente. Es exactamente lo que hace `profiles/autocomplete.env` con `4096`.

Si necesitas control fino por petición, usa `/api/generate` en vez del endpoint OpenAI-compatible.

---

# 16. Autocompletado inline en Neovim

## 16.1 Por qué no Supermaven

El plugin `supermaven-nvim` sigue funcionando como cliente, pero el backend rechaza las peticiones de completado de esta cuenta. Evidencia recogida en este equipo:

1. El agente conecta, se identifica (`UserStatus: Free Tier`) y recibe un `popup`:

   ```json
   {"kind":"popup","message":"We don't have an active payment method on file for your account..."}
   ```

2. Inmediatamente después, cada `cursor_update` provoca un **RST del servidor ~1 RTT después** (~95 ms), no un cierre ordenado.
3. Conexiones sin peticiones de completado aguantan minutos; el fallo sólo aparece al pedir completado.
4. Supermaven anunció su cierre el **21-nov-2025** y sólo prometió inferencia gratuita a clientes existentes. La cuenta de este equipo se activó el **27-dic-2025**.

No es un problema local: reautenticar, borrar el binario o tocar DNS/TLS no cambia nada. De ahí la migración a un modelo local.

## 16.2 Arquitectura del autocompletado local

```text
Neovim (insert mode)
   │
   │  minuet-ai.nvim: debounce + throttle
   v
POST http://127.0.0.1:11434/v1/completions
   │  { model, prompt: <antes del cursor>, suffix: <después del cursor> }
   v
Ollama aplica la plantilla FIM del modelo
   │  <|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>
   v
qwen2.5-coder:1.5b (Vulkan, 100% GPU)
   │
   │  NDJSON en streaming
   v
minuet dibuja el ghost text → <C-a> acepta
```

## 16.3 Instalación

```bash
# Opción A: desde este repo
./install.sh --neovim

# Opción B: manual
cp nvim/minuet.lua ~/.config/nvim/lua/plugins/minuet.lua
```

Con lazy.nvim el archivo se carga solo (está en `lua/plugins/`). En el primer arranque descarga el plugin. **Desactiva cualquier otro plugin de completado inline** para no tener dos ghost texts compitiendo.

Requisitos:

```bash
ollama pull qwen2.5-coder:1.5b
./scripts/ollama-profile.sh apply autocomplete --preload
```

## 16.4 Parámetros de la configuración

| Opción | Valor aquí | Por qué |
| ------ | ---------- | ------- |
| `provider` | `openai_fim_compatible` | Usa `/v1/completions` con `prompt`+`suffix`, que es lo que Ollama espera para FIM |
| `n_completions` | `1` | Cada item extra es otra petición HTTP completa |
| `context_window` | `8000` caracteres | ≈2000 tokens; cabe en `num_ctx=4096` dejando espacio para generar |
| `context_ratio` | `0.75` | 3:1 a favor del texto anterior al cursor |
| `debounce` | `150` ms | Espera a que dejes de teclear antes de pedir |
| `throttle` | `0` | Sin límite extra: el debounce ya controla la frecuencia |
| `request_timeout` | `1.5` s | Con streaming, corta si no hay texto útil |
| `notify` | `error` | Evita avisos en cada petición |
| `virtualtext.auto_trigger_ft` | `{'*'}` | Todos los filetypes menos los excluidos |
| `auto_trigger_ignore_ft` | cpp, gitcommit, lazy, … | El 1.5B sufre con C++ templado y en buffers de UI molesta |
| `api_key` | `'TERM'` | Ollama lo ignora, pero minuet exige un nombre de variable existente |
| `optional.max_tokens` | `64` | Suficiente para 2–4 líneas |
| `optional.temperature` | `0` | Completado determinista |

Keymaps (idénticos en espíritu a los que ya usabas):

| Tecla | Acción |
| ----- | ------ |
| `<C-a>` | Aceptar la sugerencia completa |
| `<C-w>` | Aceptar sólo la primera línea |
| `<M-C-a>` | Aceptar N líneas (pregunta cuántas) |
| `<M-]>` / `<M-[>` | Siguiente / anterior sugerencia |
| `<C-]>` | Descartar |

## 16.5 Cambiar de modelo sin editar el archivo

```vim
:Minuet change_model qwen2.5-coder:7b
:Minuet virtualtext toggle
```

O por variables de entorno antes de abrir Neovim:

```bash
OLLAMA_FIM_MODEL=qwen2.5-coder:7b nvim
```

El 7B ocupa ~4,7 GB y da mejor calidad a costa de latencia (§17). En `16 GB` conviene no tenerlo cargado junto a `gpt-oss:20b`.

## 16.6 Verificar que funciona

```bash
# 1. El modelo está cargado en GPU
ollama ps

# 2. El endpoint FIM responde
./scripts/bench.sh qwen2.5-coder:1.5b --warm-only

# 3. En Neovim, tras escribir
:checkhealth minuet
:Minuet virtualtext toggle   # apagar/encender para ver si el estado cambia
```

Si `ollama ps` muestra `CONTEXT 4096` y `100% GPU`, el camino está completo.

---

# 17. Benchmarks medidos en este equipo

Metodología: misma petición FIM real (código Lua con hueco), `temperature=0`, `stream=true`, medido con `scripts/bench.sh`. TTFT = tiempo hasta el primer token con contenido.

Hardware: AMD RX 9060 XT 16 GB (Navi 44), Vulkan, Arch Linux, kernel 7.2.14, Ollama 0.40.15.

## 17.1 `qwen2.5-coder:1.5b` — `num_ctx=4096`

| Escenario | TTFT | Total (64 tok) | tok/s | Carga |
| --------- | ---- | -------------- | ----- | ----- |
| Frío (modelo descargado) | 1 279 ms | 1,68 s | 160 | 0,90 s |
| Caliente | **9 ms** | **0,38 s** | **174** | 0,00 s |

## 17.2 `qwen2.5-coder:1.5b` — `num_ctx=65536` (mismo modelo, contexto distinto)

| Escenario | TTFT | Total | tok/s | Carga |
| --------- | ---- | ----- | ----- | ----- |
| Caliente tras cambiar ctx | 1 354 ms | 1,74 s | 166 | 1,19 s |

Confirma que **cambiar el contexto obliga a recargar**. La velocidad de generación es la misma; el castigo está en la carga.

## 17.3 `gpt-oss:20b` — `num_ctx=65536`

| Escenario | TTFT | Total (48 tok) | tok/s | Carga |
| --------- | ---- | -------------- | ----- | ----- |
| Frío | **20 790 ms** | 21,44 s | — | 20,8 s |
| Caliente | 80 ms | 0,74 s | 65 | 0,00 s |

Dos conclusiones:

1. **No sirve para inline**: 20 s hasta el primer token tras 5 minutos de inactividad.
2. **No es un modelo FIM**: sus capabilities son `completion, tools, thinking`, sin `insert`. No rellena huecos aunque le pases `suffix`.

## 17.4 `qwen2.5-coder:7b` — `num_ctx=4096`

| Escenario | TTFT | Total (64 tok) | tok/s | Carga |
| --------- | ---- | -------------- | ----- | ----- |
| Frío (modelo descargado) | 4 330 ms | 5,50 s | 54,6 | 4,20 s |
| Caliente | **20 ms** | **1,13 s** | **57,4** | 0,00 s |

Modelo `7.6B Q4_K_M`, `capabilities: completion, tools, insert` (sí es FIM), 4,6 GB en VRAM con 4K de contexto.

Comparado con el 1.5b: el TTFT caliente es igual de bueno (20 ms vs 9 ms), pero **genera 3× más lento** (57 vs 174 tok/s). Para una línea típica de 15 tokens son ~290 ms frente a ~100 ms. El cold start también triplica (4,2 s vs 0,9 s).

## 17.5 Cómo reproducirlo

```bash
./scripts/bench.sh qwen2.5-coder:1.5b
./scripts/bench.sh qwen2.5-coder:1.5b --ctx 8192
./scripts/bench.sh qwen2.5-coder:7b
./scripts/bench.sh gpt-oss:20b --ctx 65536 --tokens 48
```

`--warm-only` evita descargar el modelo y mide sólo el caso caliente. Sin ese flag, el script ejecuta `ollama stop` antes de la primera medición.

## 17.6 Interpretación para uso real

- Con el perfil `autocomplete` (`keep_alive=5m`) el modelo **se carga en la primera petición y se descarga solo tras 5 minutos de inactividad**. Ese primer completion tras el idle cuesta ~1,3 s de TTFT; todos los siguientes, 9 ms.
- El total de 380 ms para 64 tokens es el peor caso (completion larga). Una línea típica son 10–20 tokens: ~100 ms.
- Si cambias al 7b, espera ~3× más tiempo por token. Sigue siendo usable, pero deja de sentirse instantáneo en completions largas.
- Si ves 1–2 s por pulsación, no es el modelo: es `keep_alive` sin fijar, contexto demasiado grande, o el modelo se está recargando por cambio de perfil.

---

# 18. Operación diaria y resolución de problemas

## 18.1 Checklist cuando no hay sugerencias

```bash
# 1. ¿Servicio arriba?
systemctl is-active ollama.service

# 2. ¿API responde?
curl -fsS http://127.0.0.1:11434/api/version

# 3. ¿Modelo instalado?
ollama list | grep qwen2.5-coder

# 4. ¿Modelo en GPU?
ollama ps

# 5. ¿El endpoint FIM responde?
curl -s http://127.0.0.1:11434/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-coder:1.5b","prompt":"def f():\n    ","suffix":"\n","max_tokens":8}'
```

Si 1–5 pasan, el problema está en Neovim: `:checkhealth minuet`, `:lua =vim.lsp.get_clients()`, y confirma que el spec de minuet se cargó (`:Lazy`).

## 18.2 Problemas frecuentes

| Síntoma | Causa | Solución |
| ------- | ----- | -------- |
| Primera sugerencia tarda 1–2 s y luego va rápido | Modelo en frío tras 5 min de inactividad | Es el comportamiento on-demand; sube `OLLAMA_KEEP_ALIVE` a `30m` si molesta |
| Todas las sugerencias tardan >1 s | Contexto global en 64K | Usa el perfil `autocomplete` (4K) |
| `ollama ps` muestra `CPU/GPU` o `100% CPU` | Offloading por falta de VRAM | Baja de modelo o cuantización; `OLLAMA_GPU_OVERHEAD` |
| Sugerencias cortadas a media palabra | `max_tokens` bajo | Subir a 96–128 |
| Repite el texto que ya está escrito | Penalización de repetición | `repeat_penalty 1.0`, `presence_penalty 0` |
| No respeta saltos de línea | `penalize_newline` activo | `"penalize_newline": false` con `/api/generate` |
| Ghost text aparece en buffers de UI | Faltan exclusiones | Añadir filetype a `auto_trigger_ignore_ft` |
| Tras cambiar de perfil todo va lento | Modelos expulsados de VRAM | Volver a precalentar; o usar `hybrid` |
| `CUDA out of memory` / runner muere | Dos modelos grandes a la vez | `OLLAMA_MAX_LOADED_MODELS=1` o modelo menor |
| El servicio no arranca tras editar el drop-in | Sintaxis de systemd | `systemd-analyze verify ollama.service`; `journalctl -u ollama -n 50` |

## 18.3 Comandos de referencia rápida

```bash
# Estado completo
./scripts/healthcheck.sh

# Perfiles
./scripts/ollama-profile.sh list
./scripts/ollama-profile.sh current
./scripts/ollama-profile.sh apply autocomplete --dry-run
sudo ./scripts/ollama-profile.sh apply autocomplete --preload

# Benchmarks
./scripts/bench.sh qwen2.5-coder:1.5b
./scripts/bench.sh --warm-only

# Servicio
systemctl status ollama.service
journalctl -u ollama.service -f
ollama ps
ollama list
```

## 18.4 Qué NO hacer

- No cambiar `OLLAMA_CONTEXT_LENGTH` por petición esperando que sea gratis: recarga el modelo.
- No poner `OLLAMA_NUM_PARALLEL` alto "por si acaso": multiplica la KV cache y reduce la velocidad por petición.
- No ejecutar un segundo `ollama serve` en una terminal mientras el servicio está activo: compiten por el puerto y por la GPU.
- No fijar `OLLAMA_KEEP_ALIVE=-1` con un modelo de 20B si también usas el escritorio: se queda con la VRAM.
- No usar `OLLAMA_DEBUG_LOG_REQUESTS=1` de forma permanente: escribe tu código en el journal.

---

## Decisión inicial

Configuración de partida, ya validada en este equipo (10-nov-2026):

```text
Runtime:      Ollama 0.40.15
Backend GPU:  Vulkan (paquete ollama-vulkan)
Modelos:      qwen2.5-coder:1.5b  → autocompletado inline en Neovim
              gpt-oss:20b         → agente en OpenCode
Contexto:     4K (autocompletado) / 64K (agente), por perfil
KV cache:     q8_0 + flash attention
Parallelism:  2 (autocompletado) / 1 (agente)
Modelos en VRAM: 2 como máximo
```

Los dos modelos no compiten si se cambia de perfil: `autocomplete` deja cargados coder + chat, `agent` deja sólo `gpt-oss`. Gemma 4 12B es la alternativa para más contexto con margen de VRAM; Qwen3.8 27B Q3 es la prueba avanzada en llama.cpp. Mantén el criterio de selección basado en diffs correctos, tests ejecutados, tool calling fiable, contexto retenido y rendimiento real, no sólo en el tamaño del modelo o una puntuación sintética.

```bash
ollama pull qwen2.5-coder:1.5b   # 986 MB — autocompletado
ollama pull gpt-oss:20b          #  13 GB — agente
# opcionales
ollama pull qwen2.5-coder:7b     # 4,7 GB — más calidad, más latencia
ollama pull gemma4:12b
ollama pull qwen3.8:27b-q4_K_M
```

# TOOLS O REQUESUS EXTRAS

sudo pacman -S amdgpu_top
