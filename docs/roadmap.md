# Próximos pasos (roadmap)

Plan de diseño para lo que sigue. No es implementación: es el "cómo lo haría y
por qué", para discutir antes de codear.

---

## 1. Feature `agent` — puente bidireccional con el agente de IA

Objetivo: que un agente externo (Claude Code, etc.) pueda **leer, comentar,
responder, resolver y limpiar** comentarios, y aplicar cambios de código **en
vivo** sobre la misma instancia de Neovim que estás usando, sin choques.

### 1.1 Transporte: RPC nativo de Neovim (sin sockets propios)

- El "servidor" es el mismo proceso `nvim` (o uno headless con `--listen`).
- El agente invoca funciones expuestas en `_G.ReviewAgent` vía
  `nvim --server <sock> --remote-expr 'luaeval("ReviewAgent.xxx(_A)", <json>)'`.
- Sin dependencias nuevas, sin HTTP. Deshabilitado por defecto (`opts.agent.enabled`),
  porque expone superficie de escritura remota.
- Todas las funciones son **serializables**: reciben/devuelven `string` (JSON) o
  primitivos; nunca extmark ids ni tablas Lua crudas.

### 1.2 Concurrencia y "quién manda" — la clave para que no rompa

**Comentarios (estado):** no hay concurrencia real. Los `--remote-expr` se
ejecutan en el **event loop principal** de Neovim, uno a la vez, intercalados
con tus acciones. Es decir: agente y usuario mutan `core.state`
**serializados**, nunca en simultáneo → no hay data race. `core.state` sigue
siendo la única fuente de verdad; cada mutación emite `comments:changed` y la UI
se redibuja igual venga de vos o del agente. Cada mutación del agente persiste
inmediatamente (`core.state.persist()`).

**Código (ediciones en vivo):** acá está el cuidado real.
- El agente **NO debe escribir el archivo en disco** por detrás (pisaría tus
  cambios sin guardar y rompería el buffer). En su lugar, edita a través del
  **buffer** con `nvim_buf_set_text`/`set_lines`. Ventajas:
  - Los **extmarks de comentarios se re-anclan solos** (siguen la línea).
  - Las **vistas de diff se actualizan en vivo** (el diff nativo del split y el
    inline recomputan).
  - Queda en el **undo tree**: podés deshacer un cambio del agente con `u`.
- Si el archivo del agente no está abierto en un buffer, se abre (o se edita en
  memoria y se persiste), pero nunca se hace `:w` silencioso sobre algo con
  cambios sin guardar.
- **Ambos editando la misma zona:** como todo pasa por el buffer y está
  serializado, el "último en escribir" gana esa línea (comportamiento normal de
  Vim). Para evitar pisones molestos:
  - **Turno suave (soft-lock):** el agente puede marcar "estoy trabajando en
    `path:lnum-lnum`" (un extmark de "zona en edición del agente"); si estás
    escribiendo en esa zona, se difiere o se avisa. No es un lock duro, es una
    señal visual (barra/decoración) + una consulta `ReviewAgent.is_busy_zone()`.
  - **No editar mientras estás en insert:** el agente consulta el modo
    (`mode()`); si estás en insert en ese buffer, encola el cambio para cuando
    salgas (o avisa). Evita pelear teclas.
  - **Notificación:** cada edición/comentario del agente dispara un `vim.notify`
    discreto + (opcional) un salto/decoración para que sepas qué tocó.

### 1.3 API `_G.ReviewAgent` (propuesta)

Lectura:
- `list(filter?)` → JSON de comentarios. `filter`: `{ author?, path?, resolved?, answered? }`.
- `get(id)` → un comentario (con su hilo).
- `context(id)` → el comentario + las líneas de código que abarca (para que el
  agente entienda a qué se refiere sin adivinar).

Escritura de comentarios:
- `add({ path, lnum, end_lnum?, text })` → crea comentario `author="agent"` (o el
  modelo). Devuelve id.
- `reply(parent_id, text)` → crea un comentario ligado a otro (`reply_to`), típico
  para **responder/justificar** un comentario tuyo.
- `resolve(id)` / `unresolve(id)`.
- `update(id, text)`.
- `delete(id)`.
- `clean_resolved(path?)` → borra los resueltos (limpieza masiva).

Código:
- `apply_edit({ path, start_lnum, end_lnum, lines })` → edita vía buffer (ver 1.2),
  con re-anclaje de comentarios y actualización de vistas.
- `preview_edit(...)` → propone el cambio como diff sin aplicarlo (para que lo
  aceptes/rechaces vos primero) — flujo "sugerencia".

Coordinación:
- `servername()` → el socket actual.
- `mode()` / `is_busy_zone(path, lnum)` → para el turno suave.

### 1.4 Comentarios del agente: autoría, threading, filtros

Extensión del modelo de datos (compatible hacia atrás):
```
comment = {
  id, path, lnum, end_lnum, text, resolved, created_at,
  author,       -- "user" | "agent" | "<model-id>"
  reply_to?,    -- id del comentario padre (respuesta/justificación)
}
```

- **Autoría visible:** los comentarios del agente se pintan distinto (ícono 🤖 /
  color propio en gutter y badge) para distinguirlos de los tuyos.
- **Threading (respuestas ligadas):** `reply_to` liga la respuesta del agente a
  tu comentario. En el **peek** se ve el hilo completo (tu comentario + la
  respuesta/justificación del agente debajo). En la **lista** se marca si un
  comentario tuyo **fue respondido** y por quién.
- **Filtros** (extender el `f` de la lista y `list(filter)`):
  - por autor: míos / del agente / todos.
  - por estado: abiertos / resueltos / todos.
  - **respondidos / sin responder**: para que veas de un vistazo qué preguntas
    tuyas ya tienen justificación del agente y cuáles no.
- **Flujo típico:**
  1. Dejás comentarios (dudas, pedidos).
  2. `:Rya` copia el markdown agent-ready y se lo das al agente (o el agente lo
     lee por `ReviewAgent.list`).
  3. El agente: aplica cambios (`apply_edit`), **responde ligado** a cada
     comentario (`reply`) con la justificación, y opcionalmente resuelve.
  4. Vos ves en vivo: el badge/gutter marca que hay respuesta del agente; abrís
     el peek y leés la justificación; aceptás (queda resuelto) o reabrís.
  5. `clean_resolved` para limpiar lo cerrado.

### 1.5 Ideas extra para mejor flujo

- **Marcador "respondido por agente"** en el gutter (color/ícono distinto) para
  saltar rápido a lo contestado.
- **Historial por comentario:** guardar los replies como hilo ordenado por fecha.
- **"Aceptar respuesta":** un comando que marca el hilo como resuelto y (opcional)
  archiva.
- **Sugerencias no aplicadas:** `preview_edit` deja un diff propuesto que podés
  aplicar con una tecla (como "apply suggestion" de GitHub).
- **Notas de sesión:** el agente puede dejar un comentario "resumen" a nivel
  archivo (lnum=1) con lo que hizo.
- **Anti-eco:** al re-anclar tras una edición del agente, no re-emitir eventos en
  loop (reusar el guard de `sync`).

### 1.6 Orden de implementación sugerido
1. Modelo: agregar `author` y `reply_to` a `core.state` (con defaults; retro-compatible).
2. Render/gutter/peek: distinguir autor + mostrar hilos.
3. Lista: filtro por autor y por respondido/sin responder.
4. `rpc.lua`: list/get/add/reply/resolve/unresolve/update/delete/clean_resolved.
5. `apply_edit` vía buffer + re-anclaje + turno suave.
6. `init.lua`: `_G.ReviewAgent`, `opts.enabled`, notificaciones.
7. Docs del protocolo + ejemplos `--remote-expr`.

---

## 2. Limpiar la config de Neovim

Objetivo: dejar solo los plugins que usás, entendiendo dependencias, sin romper nada.

### 2.1 Inventario
- Listar todo lo declarado en `~/.config/nvim/lua/plugins/*.lua`.
- Para cada plugin: ¿lo usás? (comando/keymap/evento que dispare) ¿o es
  dependencia de otro?

### 2.2 Clasificar
- **Directo** (lo usás vos): editor, LSP, treesitter, telescope, neo-tree, etc.
- **Dependencia** (lo pide otro): p. ej. `plenary` (telescope/neo-tree/review),
  `nui` (review popups), `nvim-web-devicons`, `window-picker` (neo-tree).
  Estos **no se borran** aunque no los "uses" directamente.
- **Candidato a sacar:** no referenciado por nadie y no lo usás.

### 2.3 Cómo manejar dependencias (lazy.nvim)
- Si un plugin está en `dependencies = { ... }` de otro, lazy lo instala solo; no
  hace falta declararlo aparte.
- Antes de sacar algo, buscar si aparece como `dependencies` en otros specs.
- `:Lazy` muestra el árbol y quién carga qué; `require("lazy").plugins()` da la lista.

### 2.4 Método seguro
1. Hacer el inventario y marcar candidatos (sin borrar).
2. Desactivar (no borrar) con `enabled = false` los candidatos, uno o unos pocos
   por vez.
3. Reiniciar, usar normal un rato, ver si falta algo.
4. Si todo bien, eliminar el spec; si algo se rompe, revertir.
5. `:Lazy clean` para quitar los que ya no están declarados.

### 2.5 Entregable
Un informe: tabla de plugins (directo / dependencia / candidato a sacar), con el
motivo de cada uno y qué depende de qué. Se puede generar leyendo
`lua/plugins/*.lua`. **Se puede hacer como tarea aparte cuando quieras** —
avisá y armo el inventario real de tu config.
</content>
