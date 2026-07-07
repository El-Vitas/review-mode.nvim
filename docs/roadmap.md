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

### 1.2 Separación de responsabilidades

Regla clara:
- **El código lo escribe el agente LIBREMENTE en disco** (con sus propias
  herramientas), FUERA de Neovim. review.nvim NO edita código y NO interviene en
  cómo el agente modifica archivos.
- **Los comentarios SÍ pasan por Neovim** (vía `_G.ReviewAgent`, sobre
  `core.state`), que es la única fuente de verdad de los comentarios.

Entonces el problema NO es "editar código sin choques" (eso lo maneja el agente
en disco), sino: **cuando el agente cambia un archivo en disco, Neovim tiene que
enterarse, recargar el buffer y RE-ANCLAR los comentarios** (porque una edición
en disco NO mueve los extmarks del buffer).

### 1.3 Reconciliación: detectar cambios en disco y re-anclar comentarios

**Comentarios (estado):** no hay concurrencia real. Los `--remote-expr` corren
serializados en el event loop principal, intercalados con tus acciones → agente
y usuario mutan `core.state` uno a la vez, sin data race. Cada mutación emite
`comments:changed`, la UI se redibuja y se persiste.

**Cambios de código en disco (el punto delicado):**

1. **Detección.** `autoread` + un autocmd `FileChangedShell`/`FileChangedShellPost`
   (o un `checktime` disparado por el agente vía RPC al terminar de editar, p. ej.
   `ReviewAgent.notify_changed(path)`). Así Neovim sabe que el archivo cambió.

2. **Buffer SIN cambios sin guardar (caso normal):** el usuario está revisando
   (leyendo/comentando), no editando código → el buffer no está `modified`. Se
   recarga automáticamente. Pero al recargar **se pierden los extmarks**, así que
   hay que **re-anclar** los comentarios:
   - Antes de recargar, capturar las líneas viejas del buffer.
   - Después de recargar, tomar las líneas nuevas (del disco).
   - Diffear viejo vs nuevo (`vim.diff`) y **remapear el `lnum`/`end_lnum` de cada
     comentario** a través de los hunks: los comentarios en zonas sin cambios se
     corren limpio; los que caen DENTRO de una zona modificada por el agente se
     marcan como **`stale` (posiblemente desubicado)** con un indicador visual,
     para que los revises.
   - Ancla de respaldo por **contenido**: guardar el texto de la línea comentada
     (`anchor_text`) para relocalizar por búsqueda si el diff no alcanza.
   - Luego re-render + persist con las posiciones nuevas.

3. **Buffer CON cambios sin guardar (conflicto real):** vos editaste código y no
   guardaste, y el agente tocó el mismo archivo en disco → divergieron. Neovim
   **no debe pisar** tus cambios. Estrategia:
   - `FileChangedShell` con buffer `modified` → NO auto-recargar; avisar y ofrecer
     opciones: ver el diff (buffer vs disco), recargar descartando lo tuyo, o
     mantener lo tuyo.
   - **Prevención:** el agente puede preguntar por RPC
     `ReviewAgent.is_modified(path)` antes de editar; si está `modified`, que evite
     ese archivo o te avise. Es lo ideal: como el agente escribe libre en disco,
     que primero consulte si ese archivo lo estás editando sin guardar.

4. **Vistas de diff:** tras la recarga, el buffer = contenido nuevo del disco;
   inline/split recomputan contra HEAD solos (comparan buffer vs HEAD). Sin
   trabajo extra.

**Notificación:** cuando el agente comenta/responde/resuelve, un `vim.notify`
discreto (y opcional salto/decoración) para que sepas qué tocó.

### 1.4 API `_G.ReviewAgent` (propuesta)

Solo comentarios y coordinación. **El código NO pasa por acá** — lo escribe el
agente en disco con sus herramientas.

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

Coordinación con la edición en disco:
- `is_modified(path)` → `boolean`: ¿ese archivo está abierto en Neovim con cambios
  SIN guardar? El agente lo consulta ANTES de editar en disco, para no chocar con
  algo que estás editando (ver 1.3.3).
- `notify_changed(path)` → el agente avisa que terminó de editar ese archivo en
  disco; Neovim hace `checktime`, recarga y re-ancla los comentarios (ver 1.3.2).
- `servername()` → el socket actual (para que el agente sepa a dónde conectarse).

### 1.5 Comentarios del agente: autoría, threading, filtros

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
  3. El agente **edita el código en disco por su cuenta** y, por RPC, **responde
     ligado** a cada comentario (`reply`) con la justificación, opcionalmente lo
     resuelve, y avisa `notify_changed(path)` de los archivos que tocó.
  4. Neovim recarga esos archivos y re-ancla los comentarios (1.3.2). Vos ves en
     vivo: el badge/gutter marca que hay respuesta del agente; abrís el peek y
     leés la justificación; aceptás (queda resuelto) o reabrís.
  5. `clean_resolved` para limpiar lo cerrado.

### 1.6 Ideas extra para mejor flujo

- **Marcador "respondido por agente"** en el gutter (color/ícono distinto) para
  saltar rápido a lo contestado.
- **Marcador `stale`** en comentarios cuya línea cayó dentro de una zona que el
  agente cambió en disco (re-anclaje incierto) → los revisás vos.
- **Historial por comentario:** guardar los replies como hilo ordenado por fecha.
- **"Aceptar respuesta":** un comando que marca el hilo como resuelto y (opcional)
  archiva.
- **Notas de sesión:** el agente puede dejar un comentario "resumen" a nivel
  archivo (lnum=1) con lo que hizo.
- **Anti-eco:** al re-anclar tras una recarga, no re-emitir eventos en loop.

### 1.7 Orden de implementación sugerido
1. Modelo: agregar `author`, `reply_to`, `anchor_text`, `stale` a `core.state`
   (con defaults; retro-compatible).
2. Render/gutter/peek: distinguir autor + mostrar hilos + marca `stale`.
3. Lista: filtro por autor y por respondido/sin responder.
4. Re-anclaje: autocmd `FileChangedShell` + remapeo de `lnum` por diff
   (viejo vs nuevo) + ancla por contenido. (El corazón del flujo con el agente.)
5. `rpc.lua`: list/get/context/add/reply/resolve/unresolve/update/delete/
   clean_resolved + is_modified/notify_changed.
6. `init.lua`: `_G.ReviewAgent`, `opts.enabled`, notificaciones.
7. Docs del protocolo + ejemplos `--remote-expr`.

### 1.8 Ideas de tuicr (referencia, no copiar)

Revisado `~/Dev/tuicr-fork` (Rust). Valida gran parte de nuestro diseño y aporta:

- **`author` free-form** (`src/model/comment.rs`): el agente pasa su nombre
  (`--username "Claude …"`), el humano cae en `"user"`. Retro-compatible (JSON
  viejo rehidrata como `"user"`). → Idéntico a nuestro campo `author`.
- **Ancla por contenido** (`LineContext { new_line, old_line, content }`):
  guardan el **texto** de la línea además del número. Es exactamente nuestra idea
  de `anchor_text` para re-localizar tras un cambio en disco. → Adoptar.
- **`line_range`** (start/end inclusive) para multi-línea. → Ya lo tenemos
  (`lnum`/`end_lnum`).
- **Tipos de comentario** (`Note`/`Suggestion`/`Issue`/`Praise`/`Custom`): opción
  a futuro (no prioritario ahora).
- **Lifecycle remoto** (`LocalDraft`/`PushedDraft`/`Submitted`, `remote_*_id`,
  `commit_id`): es para integrar con PRs de GitHub. NO aplica a nuestro caso
  (review local del working tree), pero muestra el patrón si algún día
  integramos forge.

**Diferencia clave de contexto:** tuicr revisa un **diff de PR**, así que ancla
en espacio-de-diff (side Old/New + old/new lineno) contra un diff fijo. Nosotros
revisamos el **working tree en vivo**, por eso usamos **extmarks** (que siguen la
línea al editar en el buffer) + **remapeo por diff** y **ancla por contenido**
cuando el cambio viene de disco (agente). Distinto contexto, misma familia de
ideas.

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
