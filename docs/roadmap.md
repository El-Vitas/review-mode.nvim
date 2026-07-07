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

**Decisión: AUTO** (recargar solo, sin que el usuario aprete nada) — es mil veces
mejor UX. tuicr eligió manual (`:e`) porque re-fetchea diffs de PR remotos y no
tiene extmarks; nosotros SÍ tenemos extmarks y control del buffer local, así que
podemos hacer auto bien. El `:ReviewReload` manual queda como **fallback** para
el único caso que auto no puede resolver solo (conflicto con cambios sin
guardar). Para que auto quede sólido, hay que hacerlo así:

**Comentarios (estado):** no hay concurrencia real. Los `--remote-expr` corren
serializados en el event loop principal → agente y usuario mutan `core.state`
uno a la vez, sin data race. Cada mutación emite `comments:changed` y persiste.

#### La técnica clave: aplicar el cambio de disco como PATCH mínimo al buffer

El error naïve es hacer `:edit!` (recarga total): eso **destruye todos los
extmarks** → hay que re-anclar a mano y siempre queda frágil. En cambio:

1. Leer el contenido NUEVO del disco (sin tocar el buffer todavía).
2. Diffear **líneas actuales del buffer (viejo) vs disco (nuevo)** con `vim.diff`
   (`result_type = "indices"`) → hunks.
3. Aplicar **solo esos hunks** al buffer con `nvim_buf_set_lines`/`set_text`
   (de abajo hacia arriba para no invalidar índices).

Resultado: los extmarks de las zonas SIN cambios **no se mueven**, y en las zonas
con inserción/borrado **se corren solos** — exactamente como si el agente hubiera
editado dentro del buffer.

> **Validado empíricamente (nvim 0.12):** insertar líneas arriba de un extmark lo
> corre hacia abajo (row 4→5); `set_text` sin cambiar la cantidad de líneas no
> mueve un extmark posterior (2→2); borrar arriba lo sube (5→4). También
> confirmado que `vim.uv.new_fs_event` y `vim.diff` existen. La técnica del patch
> por diff re-ancla los comentarios sola. Es decir, **los comentarios se re-anclan automáticamente
vía extmarks, sin remapeo manual**. Además:
- El buffer queda `nomodified` (coincide con disco).
- Las vistas de diff (inline/split) recomputan solas (comparan buffer vs HEAD).
- Queda en el undo tree (podés deshacer el cambio del agente con `u`).

#### Detección (que sea confiable, no dependa de foco)

`autoread` + `FileChangedShell` solo chequean en ciertos eventos (foco,
CursorHold) → NO alcanza si el agente edita en background. Por eso:
- **Watcher activo:** `vim.uv.fs_event` (o `fs_poll` de fallback) por cada buffer
  de archivo del repo abierto. Al detectar cambio → correr el patch (arriba),
  con **debounce** (~100–200 ms) para agrupar ráfagas de escritura del agente.
- **Señal del agente:** `ReviewAgent.notify_changed(path)` fuerza el patch de ese
  path de inmediato (camino explícito y barato). No obligatorio, pero acelera.
- Cerrar el watcher en `BufWipeout`/`BufDelete` (sin fugas, como los otros caches).

#### Conflicto: buffer CON cambios sin guardar

Único caso donde auto NO debe actuar solo: vos editaste y no guardaste, y el
agente tocó ese archivo en disco → divergieron. **Nunca pisar lo tuyo:**
- Si el buffer está `modified` → NO aplicar el patch. Avisar (`vim.notify`) y
  ofrecer: ver diff (buffer vs disco), aplicar de todos modos, o ignorar. Acá sí
  entra el `:ReviewReload` manual.
- **Prevención:** el agente consulta `ReviewAgent.is_modified(path)` ANTES de
  editar; como escribe libre en disco, que evite (o avise sobre) los archivos que
  estás editando sin guardar.

#### Comentarios que caen dentro de un cambio

Aún con el patch, un comentario cuya línea el agente reescribió por completo
puede quedar mal ubicado. Malla de seguridad:
- **`anchor_text`** (idea de tuicr, `LineContext.content`): guardar el texto de la
  línea comentada; si tras el patch el extmark ya no cae sobre ese texto (ni
  cerca), marcar el comentario **`stale`** con indicador visual para que lo
  revises, en vez de mostrarlo confiado en el lugar equivocado.
- Registrar el HEAD-SHA de creación para poder avisar si el HEAD cambió mucho.

#### Resumen del flujo auto
disco cambia → watcher (debounce) o `notify_changed` → si buffer `modified`:
avisar + ofrecer (no pisar) · si no: patch mínimo por diff → extmarks se
re-anclan solos → marcar `stale` los dudosos (por `anchor_text`) → `nomodified` →
vistas recomputan. Todo sin que el usuario haga nada.

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
4. Re-anclaje AUTO (corazón del flujo): watcher (`vim.uv.fs_event`, debounce) +
   `notify_changed` → **patch mínimo por diff** al buffer (extmarks se re-anclan
   solos) → `anchor_text` + marca `stale` para los dudosos → conflicto si
   `modified` (no pisar). `:ReviewReload` manual como fallback.
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
