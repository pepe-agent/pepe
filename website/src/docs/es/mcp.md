---
title: Servidores MCP
description: Conecta servidores del Model Context Protocol para que tus agentes puedan llamar a sus herramientas.
---

Conecta servidores **MCP (Model Context Protocol)**, como Sentry o GitHub, y sus
herramientas quedan al alcance de los agentes como si fueran nativas. Los tokens
entran como referencias `${ENV_VAR}`.

Un servidor es de uno de dos tipos:

* **Remoto** - una URL a la que se llega por HTTP. Nada corre en tu máquina; necesitas
  la dirección y una credencial.
* **Local** - un comando que arranca por stdio bajo demanda (a través de `npx`, así que
  **no hay nada que instalar a mano**), corriendo junto a Pepe.

## Añadir un servidor

```bash
# remoto: un servidor alojado, al que se llega por HTTP
pepe mcp add memclaw --url https://memclaw.net/mcp \
  --header "Authorization: Bearer ${MEMCLAW_API_KEY}"

# local: un servidor que Pepe arranca por su cuenta
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"

pepe mcp tools sentry     # se conecta y lista sus herramientas (valida la conexión)
pepe mcp list
```

`pepe mcp tools` arranca de verdad el servidor y le pregunta qué sabe hacer, así
que también sirve de prueba de conexión. Un comando equivocado, un argumento
equivocado o un token inválido aparecen ahí, y no en mitad de una conversación.

Las definiciones de los servidores viven en `~/.pepe/config.json`, bajo `"mcp"`.

## Servidores remotos: el transporte se elige solo

Hay dos maneras en que un servidor MCP remoto puede hablar, y solo se distinguen
intentándolo: **Streamable HTTP**, que es lo que habla un servidor publicado hoy, y el
par más antiguo **HTTP+SSE**, del que algunos todavía no han migrado. Pepe prueba el más
nuevo y retrocede al otro, así que le das la URL y nada más.

Fíjalo con `--transport streamable` o `--transport sse` solo si la negociación se
equivoca. Equivocarse tiene exactamente el aspecto de una URL rota, y por eso el
retroceso es el comportamiento por defecto en vez de una opción que tendrías que conocer.

## Entrar en un servidor que pide OAuth

Algunos servidores alojados no aceptan ninguna clave de API y responden `401` hasta que
entras:

```bash
pepe mcp login memclaw
```

Pepe le pregunta al servidor dónde está su servidor de autorización, se registra allí
como cliente, abre tu navegador y guarda la concesión. Nada hay que rellenar a mano, ni
client id, ni endpoint, porque la razón de que exista el paso de descubrimiento es
justamente que nadie te contó nada de eso. Por SSH, donde no hay navegador que abrir,
imprime el enlace y acepta el código pegado.

La concesión se renueva sola cuando caduca. `pepe mcp logout NOMBRE` la olvida. La página
MCP del panel hace el mismo inicio de sesión con un botón, y muestra en qué servidores ya
has entrado.

<div class="note"><strong>Los tokens no están en <code>config.json</code>.</strong> Una clave estática que configuras tú vive en el entorno y se referencia como <code>${VAR}</code>. Una concesión OAuth no funciona así, rota por su cuenta, así que se guarda en la base de datos local de Pepe y nunca se escribe en el archivo de configuración.</div>

## Cómo se nombran las herramientas

Cada herramienta MCP se expone a los agentes como
`mcp__<servidor>__<herramienta>`. El nombre que elegiste al añadir el servidor es
el segmento del medio, así que la misma herramienta venida de dos servidores
distintos nunca colisiona.

## El alcance es solo la lista de herramientas permitidas

No hay un segundo modelo de permisos para MCP. **El alcance es la lista de
herramientas permitidas del agente.** Para dejar a un agente en *solo lectura*
frente a un servidor, dale únicamente las herramientas de lectura y deja fuera las
que modifican:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (sin mcp__sentry__update_issue, así que el agente puede mirar, pero no cambiar)
```

El comodín `mcp__sentry__*` concede de una vez todas las herramientas de ese
servidor.

Las herramientas MCP son arriesgadas, así que cada llamada sigue pasando por la
barrera de permisos. La lista de permitidas decide a qué puede recurrir el agente;
la barrera decide si esa llamada concreta sigue adelante.

## Gestionar servidores por chat

Un agente que tenga la herramienta `manage_mcp` puede añadir y validar servidores
por su cuenta, desde una conversación. También por ese camino los secretos siguen
siendo referencias `${ENV}`, así que nunca se escribe nada expandido en disco.

## Si un token se pega en claro

Pepe se negaba a guardar un servidor cuando detectaba un token en claro. Aquello
parecía responsable y no hacía nada, por *cuándo* ocurría: a esas alturas el token
ya se había escrito en un chat, así que ya había llegado al proveedor del modelo y
ya estaba en la conversación y en el trace en disco. La negativa no deshacía la
fuga. Lo único que conseguía era que el servidor no se añadiera y que la persona
no supiera por qué.

Así que el servidor se guarda, y la respuesta dice la verdad: **ese token está
comprometido, revócalo y emite otro**, pon el nuevo en una variable de entorno y
refiérete a él como `${...}`. `pepe doctor` lo sigue repitiendo, para quien no lo
leyó la primera vez. Y ahora además encuentra un token archivado bajo cualquier
nombre con pinta de credencial (`GITHUB_TOKEN`, `BRAVE_API_KEY`), algo que la
comprobación antigua, que cotejaba con una lista fija de nombres exactos, se
saltaba de largo.

<div class="note"><strong>Los secretos siguen siendo referencias.</strong> Escribe un token como <code>${SENTRY_AUTH_TOKEN}</code> y Pepe lo interpola en el momento de la lectura, sin persistir nunca el valor expandido. El valor vive en el entorno; <code>~/.pepe/config.json</code> guarda solo la referencia.</div>
