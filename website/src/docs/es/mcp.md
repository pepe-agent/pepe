---
title: Servidores MCP
description: Conecta servidores del Model Context Protocol, como GitHub o Sentry, y sus herramientas ya hechas quedan disponibles para tus agentes como si fueran nativas.
---

**MCP (Model Context Protocol)** es una forma estándar de que servicios externos ofrezcan herramientas ya hechas a agentes de IA, y muchos productos publican la suya. Conecta un servidor MCP, por ejemplo Sentry o GitHub, y sus herramientas quedan al alcance de tus agentes como si fueran nativas. Los tokens se guardan como referencias `${ENV_VAR}`.

Un servidor puede ser de dos tipos:

* **Remoto**: una URL a la que se llega por HTTP. No corre nada en tu máquina, solo necesitas la dirección y una credencial.
* **Local**: un programa que Pepe arranca bajo demanda y con el que habla directamente (a través de `npx`, así que **no hay nada que instalar a mano**), corriendo junto a Pepe.

## Añadir un servidor

```bash
# remoto: un servidor alojado, al que se llega por HTTP
pepe mcp add memclaw --url https://memclaw.net/mcp \
  --header "Authorization: Bearer ${MEMCLAW_API_KEY}"

# local: un servidor que Pepe arranca por su cuenta
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"

pepe mcp tools sentry     # conecta y lista sus herramientas (valida la conexión)
pepe mcp list
```

`pepe mcp tools` arranca el servidor de verdad y le pregunta qué sabe hacer, así que de paso funciona como prueba de conexión. Un comando mal escrito, un argumento equivocado o un token inválido aparecen ahí, no a mitad de una conversación.

Las definiciones de los servidores viven en `~/.pepe/config.json`, bajo `"mcp"`.

## Servidores remotos: el transporte se elige solo

Un servidor MCP remoto puede hablar de dos maneras, y la única forma de distinguirlas es probando: **Streamable HTTP**, que es lo que habla cualquier servidor publicado hoy, y el par más antiguo **HTTP+SSE**, del que algunos todavía no migraron. Pepe prueba primero el más nuevo y cae al otro si hace falta, así que tú solo das la URL.

Fija el transporte con `--transport streamable` o `--transport sse` únicamente si la negociación se equivoca. Un acierto fallido se ve exactamente igual que una URL rota, y por eso el mecanismo de repliegue es el comportamiento por defecto, en vez de una opción que tendrías que conocer de antemano.

## Iniciar sesión en un servidor que exige OAuth

Algunos servidores alojados no aceptan ninguna clave de API y responden `401` hasta que entras:

```bash
pepe mcp login memclaw
```

Pepe le pregunta al servidor dónde está su servidor de autorización, se registra ahí como cliente, abre tu navegador y guarda la concesión resultante. No hay nada que rellenar a mano, ni client id ni endpoint, precisamente porque el sentido de ese paso de descubrimiento es que nunca te dieron esos datos. Por SSH, donde no hay navegador que abrir, imprime el enlace y acepta el código pegado en su lugar.

La concesión se renueva sola cuando caduca. `pepe mcp logout NOMBRE` la olvida. La página MCP del panel ofrece el mismo inicio de sesión con un botón, y muestra en qué servidores ya has entrado.

<div class="note"><strong>Los tokens no van en <code>config.json</code>.</strong> Una clave estática que tú mismo configuras vive en el entorno y se referencia como <code>${VAR}</code>. Una concesión OAuth no puede funcionar así porque rota sola, así que se guarda en la base de datos local de Pepe y nunca se escribe en el archivo de configuración.</div>

## Cómo se nombran las herramientas

Cada herramienta MCP se expone a los agentes como `mcp__<servidor>__<herramienta>`. El nombre que elegiste al añadir el servidor ocupa el segmento del medio, así que la misma herramienta ofrecida por dos servidores distintos jamás choca.

## El alcance es solo la lista de herramientas permitidas

No existe un segundo modelo de permisos para MCP: **el alcance es la lista de herramientas permitidas del agente**. Para dejar a un agente en *solo lectura* frente a un servidor, dale únicamente las herramientas de lectura y deja fuera las que modifican algo:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (sin mcp__sentry__update_issue, así que el agente puede mirar, pero no cambiar nada)
```

El comodín `mcp__sentry__*` concede de golpe todas las herramientas de ese servidor.

Las herramientas MCP son arriesgadas, así que cada llamada igual pasa por la barrera de permisos. La lista de permitidas decide a qué puede recurrir el agente; la barrera decide si esa llamada concreta sigue adelante.

## Gestionar servidores desde el chat

Un agente que tenga la herramienta `manage_mcp` puede añadir y validar servidores por su cuenta, desde una conversación. También por ese camino los secretos siguen siendo referencias `${ENV}`, así que nunca se escribe nada expandido en disco.

## Si un token se pega en claro

Antes, Pepe se negaba a guardar un servidor cuando detectaba un token con pinta de estar en claro. Sonaba responsable pero no cambiaba nada, por el momento en que ocurría: para entonces el token ya se había escrito en un chat, así que ya había llegado al proveedor del modelo y ya estaba en la conversación y en el trace guardado en disco. Rechazarlo no deshacía la fuga. Lo único que lograba era que el servidor no quedara añadido y que la persona no entendiera por qué.

Así que ahora el servidor se guarda igual, y la respuesta dice la verdad tal cual es: **ese token está comprometido, revócalo y emite uno nuevo**, guarda el reemplazo en una variable de entorno y refiérete a él como `${...}`. `pepe doctor` sigue insistiendo en esto, para quien no lo leyó la primera vez. Y ahora también detecta un token guardado bajo cualquier nombre con pinta de credencial (`GITHUB_TOKEN`, `BRAVE_API_KEY`), algo que la comprobación anterior, limitada a una lista fija de nombres exactos, dejaba pasar de largo.

<div class="note"><strong>Los secretos siguen siendo referencias.</strong> Escribe un token como <code>${SENTRY_AUTH_TOKEN}</code> y Pepe lo interpola al leerlo, sin guardar nunca el valor expandido. El valor vive en el entorno; <code>~/.pepe/config.json</code> solo guarda la referencia.</div>
