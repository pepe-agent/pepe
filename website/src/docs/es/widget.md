---
title: Widget incrustable
description: Coloca una burbuja de chat en cualquier sitio web, conectada a un agente de Pepe.
---

## Widget incrustable

El widget es una burbuja de chat que colocas en cualquier página con una sola
etiqueta `<script>`. Renderiza un botón flotante, se abre en un panel de chat y
habla con un agente de Pepe por una conexión en vivo y con streaming, sin
dependencias ni paso de compilación en la página que lo incrusta.

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
rechaza desde cualquier otro lugar. Consulta [Autenticación y tokens](./auth/)
para el modelo general de tokens sobre el que se apoya esto.

### Incrústalo

Pega la etiqueta script en la página, apuntando a tu servidor Pepe:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="ctx_your_widget_token"
        data-color="#ea580c"
        data-greeting="Hi! How can I help?"
        data-position="right"></script>
```

| Atributo | Qué hace | Por defecto |
|---|---|---|
| `data-agent` | Qué agente responde. Debe coincidir con el agente del propio token. | `default` |
| `data-token` | El token de widget de `token add --widget`. | ninguno |
| `data-server` | El host al que conectarse. | el propio host del script |
| `data-color` | Color de acento para la burbuja y los botones. | `#ea580c` |
| `data-greeting` | El primer mensaje mostrado antes de que el visitante envíe nada. | "Hi! How can I help?" |
| `data-position` | `left` o `right`. | `right` |

Sin paso de compilación, sin instalar npm: `widget.js` y su hoja de estilos los
sirve directamente tu servidor Pepe en `/plugin-assets/pepe-widget/`, la misma
ruta genérica que usaría cualquier futuro activo estático de un plugin.

### Cómo funciona la sesión de un visitante

Cada visitante recibe un id aleatorio, guardado en el `localStorage` de su
navegador, enviado como la sesión de la conexión para que recargar la página
continúe la misma conversación. Por debajo, el widget habla el mismo protocolo
descrito en [WebSocket](./websocket/): `prompt` de entrada, `delta` / `done` /
`error` / `watch` de salida.

### Seguridad

- **Ligado al origen.** El WebSocket solo acepta una conexión de widget cuyo
  `Origin` del navegador coincida con el `allowed_origin` de algún token de
  widget registrado (o con el host de tu propio servidor). Una copia del script
  pegada en un sitio no registrado se rechaza antes de poder llegar al agente.
- **Fijado a un agente.** Un token de widget siempre ejecuta exactamente el
  agente para el que se creó; el widget no tiene forma de pedir otro distinto.
- **Con límite de frecuencia.** Las peticiones a través de una conexión de
  widget están limitadas (20 por minuto por defecto, ajustable con `config
  :pepe, widget_rate_limit:` / `widget_rate_window_s:` si te autoalojas y
  necesitas ajustarlo), para que un token público que vive en el código fuente
  de la página no pueda ser bombardeado. Ninguna otra superficie se ve afectada.

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
en crudo vuelve una vez en la respuesta para que lo copies en la etiqueta
script.
