---
title: Widget incrustable
description: Coloca una burbuja de chat en cualquier sitio web, conectada a un agente de Pepe.
---

## Widget incrustable

El widget es una burbuja de chat que colocas en cualquier página con una sola
etiqueta `<script>`. Renderiza un botón flotante, se abre en un panel de chat y
habla con un agente de Pepe por una conexión en vivo y con streaming, sin
dependencias ni paso de compilación en la página que lo incrusta.

<img class="doc-shot" src="/screenshots/widget-es.png" alt="El panel del widget a mitad de una conversación, respondiendo en español" />

### Crea un token de widget

La etiqueta `<script>` de un widget queda en el código fuente público de la
página, así que necesita su propio tipo de token: siempre fijado a un agente, y
ligado al origen del sitio.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` requiere `--agent`: una credencial pública siempre se fija a un
agente conocido y seguro, nunca a toda una empresa ni al ámbito raíz.
`--allowed-origin` es el esquema y host del sitio; la conexión del widget se
rechaza desde cualquier otro lugar. Consulta [Autenticación y tokens](../auth/)
para el modelo general de tokens sobre el que se apoya esto.

### O hazlo desde el panel

La sección Channels tiene un botón **+ Widget** que abre un formulario ahí
mismo (etiqueta, agente, origen permitido y apariencia) sin ir aparte a la
página de tokens. Después de crear uno, el panel muestra la etiqueta
`<script>` completa ya rellenada con el token real, el agente y la dirección
de tu propio servidor, lista para copiar y pegar. Los widgets existentes
también conservan un fragmento plegable, y su token en crudo se puede ver en
cualquier momento. A diferencia de un token de API normal, el valor de un
token de widget no es un secreto que valga la pena esconder (mira
[Seguridad](#seguridad) más abajo), así que no hay un "cópialo ahora, no lo
volverás a ver". Cambiar qué agente u origen usa un widget sigue significando
crear uno nuevo y revocar el anterior (eso sigue siendo solo por rotación),
pero la apariencia se puede editar in situ en cualquier momento.

### Define el aspecto desde el panel

El título, logo, color, tema, saludo y posición no tienen que vivir en la
etiqueta `<script>` en absoluto. Defínelos en el token del widget en su
lugar (al crearlo, o después con el botón **Editar apariencia** en un widget
existente) y el script los obtiene al cargar. La prioridad es por campo, no
todo o nada: **el valor del token gana siempre que esté definido**; un campo
sin definir en el token cae de vuelta al propio atributo `data-*` de la
etiqueta, y luego al valor por defecto integrado. Así que esto es totalmente
opcional (una incrustación simple con solo `data-token` sigue funcionando
exactamente igual que antes), y los dos se pueden mezclar libremente: color
desde el panel, saludo fijo en la etiqueta, por ejemplo. La idea es que un
ajuste de color o saludo nunca necesite volver a desplegar el sitio: cámbialo
en el panel, recarga la página, listo.

### Incrústalo

Pega la etiqueta script en la página, apuntando a tu servidor Pepe:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="pepe_your_widget_token"
        data-title="Chat"
        data-logo="https://example.com/logo.png"
        data-color="#ea580c"
        data-theme="dark"
        data-greeting="Hi! How can I help?"
        data-position="right"
        data-lang="es"></script>
```

| Atributo | Qué hace | Por defecto |
|---|---|---|
| `data-agent` | Solo cosmético: nombra la sesión local del visitante para que más de un widget pueda compartir una página sin chocar. Un token de widget siempre está bloqueado a un agente, así que esto nunca cambia quién responde de verdad. | `default` |
| `data-token` | El token de widget de `token add --widget`. | ninguno |
| `data-server` | El host al que conectarse. | el propio host del script |
| `data-title` | El texto de la cabecera del panel. | "Chat" |
| `data-logo` | Una imagen cuadrada pequeña, usada como icono de la burbuja y junto al título de la cabecera. Omítelo para mantener el icono de chat simple. | ninguno |
| `data-color` | Color de acento para la burbuja, la cabecera y los botones. | `#ea580c` |
| `data-theme` | `light` o `dark`: los colores base del panel bajo la cabecera. | `light` |
| `data-greeting` | El primer mensaje mostrado antes de que el visitante envíe nada. | según `data-lang`, en inglés si no hay ninguno |
| `data-position` | `left` o `right`. | `right` |
| `data-lang` | El idioma **del sitio** (p. ej. `pt-BR`), no el del navegador del visitante. Un sitio sabe en qué idioma está escrito, un locale de navegador solo es una suposición sobre quien lo lee. Elige el saludo integrado cuando no hay `data-greeting`, y se envía una vez al unirse para que el agente se incline hacia ese idioma desde su primera respuesta. | ninguno |

Sin paso de compilación, sin instalar npm: `widget.js` y su hoja de estilos los
sirve directamente tu servidor Pepe en `/plugin-assets/pepe-widget/`, la misma
ruta genérica que usaría cualquier futuro activo estático de un plugin.

### Cómo funciona la sesión de un visitante

Cada visitante recibe un id aleatorio, guardado en el `localStorage` de su
navegador, enviado como la sesión de la conexión para que recargar la página
continúe la misma conversación. Por debajo, el widget habla el mismo protocolo
descrito en [WebSocket](../websocket/): `prompt` de entrada, `delta` / `done` /
`error` / `watch` / `session_ended` de salida. Un indicador de puntos animados
aparece en el panel mientras el agente prepara una respuesta, así el visitante
nunca duda de si su mensaje se envió.

El botón de nueva conversación de la cabecera (un simple "+") empieza una
conversación nueva de inmediato: cierra la conexión actual, limpia el panel y
se reconecta con un id de sesión nuevo. Ese id se guarda al instante, así que
incluso recargar la página por completo sigue hablando con la conversación
nueva, no con la anterior. Si el propio agente termina la conversación (su
herramienta `end_session`), el panel muestra una pequeña nota del sistema en
su lugar y el siguiente mensaje que envíes empieza de cero, sin que haga falta
pulsar nada.

<div class="note"><strong>Sin comandos de barra.</strong> El widget habla el
protocolo de streaming de arriba, no una sesión de chat completa: no hay
<code>/model</code>, <code>/models</code> ni ningún otro comando de barra,
solo los controles propios del panel. Un widget siempre está fijado al modelo
del propio agente; para ofrecer un modelo distinto a un visitante, genera un
token de widget aparte para un agente ya configurado con ese modelo.</div>

En la página Chat del panel, las conversaciones del widget se agrupan bajo
**Widget**, un subgrupo por sitio (el `allowed_origin` del token), así que
tener más de un widget en distintos sitios mantiene sus conversaciones fáciles
de distinguir, separadas del chat propio del panel.

### Seguridad

- **Ligado al origen.** Un navegador que se conecte con un token de widget
  concreto es rechazado a menos que su `Origin` coincida con el
  `allowed_origin` de ese mismo token (o con el host de tu propio servidor).
  Una copia del script pegada en un sitio no registrado se rechaza antes de
  poder llegar al agente, y un token filtrado tampoco se puede reutilizar
  desde otro sitio, ni siquiera uno para el que este mismo servidor sirva
  otro widget.
- **Fijado a un agente.** Un token de widget siempre ejecuta exactamente el
  agente para el que se creó; el widget no tiene forma de pedir otro distinto.
- **Con límite de frecuencia.** Las peticiones a través de una conexión de
  widget están limitadas (20 por minuto por defecto, ajustable con `config
  :pepe, widget_rate_limit:` / `widget_rate_window_s:` si te autoalojas y
  necesitas ajustarlo), para que un token público que vive en el código fuente
  de la página no pueda ser bombardeado. Ninguna otra superficie se ve afectada.
- **No se trata como un secreto.** El valor en crudo de un token de widget ya
  vive en HTML público, legible con "ver código fuente" en el sitio que lo
  incrusta, así que, a diferencia de un token de API normal, se guarda
  recuperable y sigue visible en el panel/`manage_token list`. Lo que
  realmente lo protege son los tres puntos anteriores, no esconder la cadena.

<div class="note"><strong>Dale un agente acotado.</strong> Un widget da la cara
a internet sin ningún humano que apruebe llamadas a herramientas. Vincúlalo a
un agente limitado a herramientas seguras, de solo lectura o orientadas al
cliente, la misma recomendación que para cualquier canal orientado al cliente
en <a href="./security/">Seguridad y sandbox</a>.</div>

### Hazlo por chat

Un agente con la herramienta `manage_token` puede crear un token de widget en
una conversación:

> Crea un token de widget para el agente support, permitido desde https://example.com.

El agente llama a `manage_token` con `action: "create"`, `agent: "support"`,
`widget: true`, y `allowed_origin: "https://example.com"`. Crear un token no es
de solo lectura, así que la llamada pasa por la puerta de permisos; el token
en crudo vuelve en la respuesta para que lo copies en la etiqueta script, y
sigue disponible en cualquier momento con `action: "list"`, ya que un token de
widget no es un secreto que valga la pena esconder.

La apariencia funciona igual, en cualquiera de las dos acciones: pasa
cualquiera de `title`, `logo`, `color`, `theme`, `greeting`, `position` en
`create`, o después con `action: "update"` y el `id` del token:

> Cambia el saludo del widget de support a "¡Hola! ¿En qué puedo ayudarte?" y su color a #2563eb.

El agente llama a `manage_token` con `action: "update"`, `id: "<el id del
token>"`, `greeting: "¡Hola! ¿En qué puedo ayudarte?"`, y `color: "#2563eb"`;
un campo que no se incluya en la llamada mantiene su valor actual.
