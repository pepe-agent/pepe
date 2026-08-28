---
title: Widget incrustable
description: Coloca una burbuja de chat en cualquier sitio web, conectada a un agente de Pepe.
---

## Widget incrustable

El widget es una burbuja de chat que puedes poner en cualquier página con una sola etiqueta `<script>`. Se muestra como un botón flotante que se abre en un panel de chat, y habla con un agente de Pepe a través de una conexión en vivo y con streaming, sin ninguna dependencia ni paso de compilación en la página que lo incrusta.

<img class="doc-shot" src="/screenshots/widget-es.png" alt="El panel del widget a mitad de una conversación, respondiendo en español" />

### Crea un token de widget

La etiqueta `<script>` de un widget queda a la vista en el código fuente público de la página, así que necesita un tipo de token propio: siempre fijado a un agente, y atado al origen del sitio.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` exige `--agent`, porque una credencial pública siempre tiene que apuntar a un agente puntual que ya sabes que es seguro, nunca a todo un proyecto entero. `--allowed-origin` es el esquema y host del sitio; cualquier conexión que llegue desde otro lado se rechaza. Para el modelo general de tokens sobre el que se apoya esto, revisa [Autenticación y tokens](../auth/).

### O hazlo desde el panel

La sección Channels tiene un botón **+ Widget** que abre ahí mismo un formulario (etiqueta, agente, origen permitido y apariencia), sin tener que pasar por la página de tokens. Una vez creado, el panel te muestra la etiqueta `<script>` completa, ya con el token real, el agente y la dirección de tu propio servidor cargados, lista para copiar y pegar. Los widgets ya existentes también guardan ese fragmento en un bloque plegable, y puedes ver su token en crudo en cualquier momento; a diferencia de un token de API normal, el valor de un token de widget no es un secreto que valga la pena esconder (más sobre esto en [Seguridad](#seguridad)), así que no hay ningún "cópialo ahora porque no lo volverás a ver". Cambiar de agente o de origen sigue significando crear un token nuevo y revocar el anterior (eso sigue siendo solo por rotación), pero la apariencia se puede editar directamente, en cualquier momento.

### Define el aspecto desde el panel

El título, el logo, el color, el tema, el saludo y la posición ni siquiera necesitan estar en la etiqueta `<script>`. Puedes definirlos en el token del widget (al crearlo, o después con el botón **Editar apariencia** sobre un widget ya existente), y el script los va a buscar al cargar la página. La prioridad se decide campo por campo, no es todo o nada: **el valor del token gana siempre que esté definido**; si un campo queda sin definir en el token, cae de vuelta al atributo `data-*` correspondiente de la etiqueta, y de ahí al valor por defecto. Así que esto es completamente opcional (una incrustación simple con solo `data-token` sigue funcionando exactamente igual que antes), y ambas fuentes se pueden combinar libremente: el color viniendo del panel, el saludo fijo en la etiqueta, por ejemplo. La idea es que ajustar un color o un saludo nunca obligue a redesplegar el sitio: lo cambias en el panel, recargas la página, y listo.

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
        data-greeting="¡Hola! ¿En qué puedo ayudarte?"
        data-position="right"
        data-lang="es"></script>
```

| Atributo | Qué hace | Por defecto |
|---|---|---|
| `data-agent` | Es solo cosmético: le da nombre a la sesión local del visitante para que más de un widget pueda convivir en la misma página sin pisarse. Un token de widget siempre está fijado a un agente, así que esto nunca cambia quién responde de verdad. | `default` |
| `data-token` | El token de widget generado con `token add --widget`. | ninguno |
| `data-server` | El host al que se conecta. | el mismo host del script |
| `data-title` | El texto de la cabecera del panel. | "Chat" |
| `data-logo` | Una imagen cuadrada pequeña, usada como icono de la burbuja y junto al título de la cabecera. Si la omites, se mantiene el icono de chat simple. | ninguno |
| `data-color` | Color de acento para la burbuja, la cabecera y los botones. | `#ea580c` |
| `data-theme` | `light` u `dark`: los colores base del panel, debajo de la cabecera. | `light` |
| `data-greeting` | El primer mensaje que se muestra antes de que el visitante escriba nada. | se elige según `data-lang`, o en inglés si no hay ninguno |
| `data-position` | `left` o `right`. | `right` |
| `data-lang` | El idioma **del sitio**, no el del navegador del visitante (por ejemplo, `pt-BR`). Un sitio sabe en qué idioma está escrito; el idioma del navegador solo es una suposición sobre quien lo está leyendo. Se usa para elegir el saludo integrado cuando no hay `data-greeting`, y se envía una sola vez al conectar para que el agente incline su primera respuesta hacia ese idioma. | ninguno |

No hace falta paso de compilación ni instalar nada de npm: tu propio servidor Pepe sirve directamente `widget.js` y su hoja de estilos en `/plugin-assets/pepe-widget/`, la misma ruta genérica que usaría cualquier futuro plugin para sus archivos estáticos.

### Cómo funciona la sesión de un visitante

Cada visitante recibe un id aleatorio, que se guarda en el `localStorage` de su navegador y se manda como sesión de la conexión, para que recargar la página siga en la misma conversación. Por debajo, el widget habla el mismo protocolo descrito en [WebSocket](../websocket/): manda `prompt` y recibe `delta`, `done`, `error`, `watch` y `session_ended`. Mientras el agente prepara una respuesta, el panel muestra unos puntos animados, así el visitante nunca se queda dudando si su mensaje llegó.

El botón de nueva conversación en la cabecera (un simple "+") arranca una conversación nueva al instante: cierra la conexión actual, limpia el panel, y se reconecta con un id de sesión distinto. Ese id queda guardado de inmediato, así que hasta una recarga completa de la página sigue hablando con la conversación nueva, no con la anterior. Si es el propio agente el que termina la conversación (con su herramienta `end_session`), el panel muestra en su lugar una pequeña nota de sistema, y el siguiente mensaje que mandes arranca desde cero, sin que tengas que hacer clic en nada.

<div class="note"><strong>Sin comandos de barra.</strong> El widget habla el protocolo de streaming más simple descrito arriba, no una sesión de chat completa: no hay <code>/model</code>, <code>/models</code> ni ningún otro comando de barra, solo el botón de reinicio. Un widget siempre queda fijado al modelo propio de su agente; si quieres ofrecerle al visitante un modelo distinto, genera un token de widget aparte para un agente que ya tenga configurado ese otro modelo.</div>

En la página Chat del panel, las conversaciones del widget se agrupan bajo **Widget**, con un subgrupo por sitio (el `allowed_origin` del token), así que si tienes más de un widget corriendo en sitios distintos, sus conversaciones se mantienen fáciles de distinguir entre sí, y separadas del chat propio del panel.

### Seguridad

- **Atado al origen.** Un navegador que se conecte con un token de widget determinado es rechazado a menos que su `Origin` coincida exactamente con el `allowed_origin` de ese token (o con el host de tu propio servidor). Una copia del script pegada en un sitio no registrado se rechaza antes de que llegue a tocar al agente, y un token filtrado tampoco se puede reutilizar desde otro sitio, ni siquiera desde uno para el que este mismo servidor sirva otro widget.
- **Fijado a un agente.** Un token de widget siempre corre exactamente el agente para el que se creó; el widget no tiene ninguna forma de pedir otro.
- **Con límite de frecuencia.** Las peticiones a través de una conexión de widget vienen limitadas (20 por minuto por defecto, ajustable con `config :pepe, widget_rate_limit:` / `widget_rate_window_s:` si te autoalojas y lo necesitas), justamente porque un token público que vive en el código fuente de la página se presta a que lo bombardeen. Esto no afecta a ninguna otra superficie.
- **No se trata como un secreto.** El valor en crudo de un token de widget ya está expuesto en el HTML público, visible con un simple "ver código fuente" en el sitio que lo incrusta; por eso, a diferencia de un token de API normal, se guarda de forma recuperable y sigue visible en el panel o con `manage_token list`. Lo que de verdad lo protege son los tres puntos anteriores, no esconder la cadena.

<div class="note"><strong>Dale un agente acotado.</strong> Un widget queda expuesto a todo internet sin que haya ningún humano aprobando llamadas a herramientas. Vincúlalo a un agente limitado a herramientas seguras, de solo lectura o pensadas para de cara al cliente, la misma recomendación que vale para cualquier canal de cara al cliente en <a href="./security/">Seguridad y sandbox</a>.</div>

### Hazlo por chat

Un agente con la herramienta `manage_token` puede crear un token de widget directamente en la conversación:

> Crea un token de widget para el agente support, permitido desde https://example.com.

El agente llama a `manage_token` con `action: "create"`, `agent: "support"`, `widget: true`, y `allowed_origin: "https://example.com"`. Crear un token no es una operación de solo lectura, así que la llamada pasa por la barrera de permisos; el token en crudo vuelve en la respuesta para que lo copies en la etiqueta script, y sigue disponible en cualquier momento con `action: "list"`, ya que un token de widget no es un secreto que valga la pena esconder.

La apariencia funciona igual, en cualquiera de las dos acciones: pásale cualquiera de `title`, `logo`, `color`, `theme`, `greeting`, `position` a `create`, o después con `action: "update"` y el `id` del token:

> Cambia el saludo del widget de support a "¡Hola! ¿En qué puedo ayudarte?" y su color a #2563eb.

El agente llama a `manage_token` con `action: "update"`, `id: "<el id del token>"`, `greeting: "¡Hola! ¿En qué puedo ayudarte?"`, y `color: "#2563eb"`; cualquier campo que no incluyas en la llamada mantiene su valor actual.
