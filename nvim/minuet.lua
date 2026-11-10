-- minuet.lua — autocompletado inline con Ollama local
--
-- Copia este archivo a ~/.config/nvim/lua/plugins/minuet.lua (lazy.nvim lo
-- carga automáticamente desde lua/plugins/).
--
-- Requisitos:
--   1. ollama.service activo en 127.0.0.1:11434
--   2. modelo FIM descargado:  ollama pull qwen2.5-coder:1.5b
--   3. perfil aplicado:        ./scripts/ollama-profile.sh apply autocomplete
--
-- Variables de entorno opcionales (para cambiar sin editar este archivo):
--   OLLAMA_FIM_URL    por defecto http://127.0.0.1:11434/v1/completions
--   OLLAMA_FIM_MODEL  por defecto qwen2.5-coder:1.5b

return {
    'milanglacier/minuet-ai.nvim',
    event = 'InsertEnter', -- no cargar nada hasta que entres en insert mode
    config = function()
        require('minuet').setup {
            provider = 'openai_fim_compatible',

            -- Un solo completion: para modelos locales cada item extra es otra
            -- petición HTTP completa.
            n_completions = 1,

            -- Caracteres de contexto (antes + después del cursor) que se envían.
            -- 8000 ≈ 2000 tokens; deja margen dentro de num_ctx=4096.
            context_window = 8000,
            context_ratio = 0.75, -- 3:1 a favor del texto anterior al cursor

            -- Con el modelo caliente el TTFT es de ~10 ms, así que se puede
            -- pedir pronto. Si tu GPU es más lenta, sube debounce a 300-400.
            debounce = 150,
            throttle = 0,

            -- Streaming + timeout corto: si a los 1.5 s no hay texto útil,
            -- cancela. Con el perfil autocomplete (keep_alive=-1) sobra.
            request_timeout = 1.5,

            notify = 'error', -- 'debug' | 'verbose' | 'warn' | 'error' | false

            virtualtext = {
                -- '*' = todos los filetypes; las exclusiones van abajo
                auto_trigger_ft = { '*' },
                auto_trigger_ignore_ft = {
                    'cpp', -- el modelo pequeño sufre con C++ templado
                    'gitcommit',
                    'lazy',
                    'mason',
                    'neo-tree',
                    'TelescopePrompt',
                    'help',
                    'checkhealth',
                },
                keymap = {
                    accept = '<C-a>', -- aceptar la sugerencia completa
                    accept_line = '<C-w>', -- aceptar sólo la primera línea
                    accept_n_lines = '<M-C-a>', -- pedir N líneas
                    next = '<M-]>', -- siguiente sugerencia
                    prev = '<M-[>', -- sugerencia anterior
                    dismiss = '<C-]>', -- descartar
                },
            },

            provider_options = {
                openai_fim_compatible = {
                    -- Ollama ignora el valor, pero la API de OpenAI lo exige
                    -- y minuet valida que exista como variable de entorno.
                    api_key = 'TERM',
                    name = 'Ollama-local',
                    end_point = vim.env.OLLAMA_FIM_URL
                        or 'http://127.0.0.1:11434/v1/completions',
                    model = vim.env.OLLAMA_FIM_MODEL or 'qwen2.5-coder:1.5b',
                    stream = true,
                    optional = {
                        max_tokens = 64,
                        temperature = 0,
                        top_p = 0.9,
                        -- NO uses `stop`: el template FIM del modelo ya corta
                        -- en <|fim_middle|>. Añadirlo aquí corta en seco.
                    },
                },
            },
        }
    end,
}
