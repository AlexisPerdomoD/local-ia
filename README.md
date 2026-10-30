# Local LLM Workstation

Guía para ejecutar modelos LLM locales orientados a programación y agentes de código en **Arch Linux + AMD Radeon RX 9060 XT de 16 GB + OpenCode**.

> **Estado de esta guía:** 30 de octubre de 2026. Los modelos, etiquetas de Ollama, paquetes de Arch y opciones de los runtimes cambian con frecuencia. Comprueba siempre las páginas oficiales enlazadas antes de automatizar instalaciones.

## Objetivo

Construir un entorno local que permita usar OpenCode sobre repositorios reales —especialmente proyectos Go, Python/FastAPI y TypeScript/Node— con capacidad para:

- Explorar un repositorio y localizar el código relevante.
- Razonar sobre cambios que afectan varios archivos.
- Editar código, ejecutar comandos y pruebas mediante herramientas de OpenCode.
- Mantener suficiente contexto durante una tarea.
- Ejecutar el modelo en la GPU AMD, evitando offloading a RAM salvo cuando se busque deliberadamente probar modelos mayores.
- Cambiar entre modelos y runtimes sin rehacer la instalación.

La primera fase usa **Ollama + Vulkan + OpenCode**. La segunda, opcional, añade **llama.cpp** para probar GGUF y ajustar con más precisión la inferencia.

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

# 11. Estructura propuesta para este repositorio

Empieza con el README y añade scripts pequeños, idempotentes y separados por responsabilidad. No mezcles instalación del sistema, configuración del servicio, descarga de modelos y benchmarks en un único script gigante.

```text
local-llm-workstation/
├── README.md
├── .gitignore
├── scripts/
│   ├── check-system.sh       # GPU, driver, Vulkan, RAM, paquetes y versiones
│   ├── install-ollama.sh     # paquetes Arch y habilitar el servicio
│   ├── configure-ollama.sh   # override systemd y parámetros seleccionados
│   ├── install-opencode.sh   # instalación opcional de OpenCode
│   ├── pull-models.sh        # descarga selectiva de modelos
│   ├── health-check.sh       # API, servicio, Vulkan y ollama ps
│   └── benchmark.sh          # captura metadatos y resultados de pruebas
├── config/
│   ├── systemd/
│   │   └── ollama.conf       # override documentado, no archivo unit completo
│   └── opencode/
│       └── opencode.json    # configuración de ejemplo sin secretos
├── docs/
│   ├── model-selection.md    # decisiones y cambios en modelos
│   ├── ollama.md             # tuning y operación
│   └── llama-cpp.md          # compilación, GGUF y Vulkan
└── benchmarks/
    └── README.md             # metodología y resultados
```

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

## Decisión inicial

Para empezar con una configuración funcional y sin complejidad innecesaria:

```text
Runtime:      Ollama
Backend GPU:  Vulkan
Modelo:       gpt-oss:20b
Contexto:     64K
KV cache:     q8_0 (si la combinación de backend/modelo es estable)
Parallelism:  1
Agente:       OpenCode
```

Primero mide esa combinación sobre Owned. Gemma 4 12B será la alternativa para más contexto y margen de VRAM. Qwen3.8 27B Q3 será la prueba avanzada en llama.cpp. Mantén el criterio de selección basado en diffs correctos, tests ejecutados, tool calling fiable, contexto retenido y rendimiento real, no solo en el tamaño del modelo o una puntuación sintética.

ollama pull gpt-oss:20b
ollama pull gemma4:12b
ollama pull qwen3.8:27b-q4_K_M

# TOOLS O REQUESUS EXTRAS

sudo pacman -S amdgpu_top
