---
title: Plugins
description: Extiende Pepe con herramientas y canales propios instalando plugins con su propia configuración.
---

Un plugin añade una **herramienta** que el modelo puede invocar, o un
**proveedor de canal** (una nueva plataforma de mensajería), o ambos: Elixir
compilado en tiempo de ejecución desde `~/.pepe/plugins/`, sin rebuild. Estas
son las únicas dos formas que puede tener un plugin hoy; un módulo se compara
con la forma que implementa.

## El comportamiento Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

| Callback | Propósito |
|---|---|
| `name/0` | El nombre de función que invoca el modelo, por ejemplo `"read_file"`. Debe ser único entre todas las herramientas: un plugin nunca gana una colisión de nombre contra una herramienta integrada. |
| `spec/0` | La especificación de función al estilo OpenAI: nombre, descripción en lenguaje llano y un JSON Schema para los parámetros. Es lo que el modelo lee para decidir cuándo y cómo invocar la herramienta. |
| `run/2` | Ejecuta la llamada. `args` son los argumentos decodificados (un mapa con claves de tipo cadena); `ctx` lleva el contexto de la ejecución actual (abajo). Devuelve `{:ok, text}` o `{:error, message}`: en cualquier caso se convierte en cadena y vuelve al modelo, así que escríbelo para que el modelo lo lea. |

`Pepe.Tools.Tool.function/3` construye el sobre de la especificación por ti,
así que solo rellenas el nombre, la descripción y los parámetros.

Una herramienta completa y funcional: guárdala como un `.exs` e instálala
(ver abajo):

```elixir
defmodule MyPlugin.Reverse do
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "reverse_text"

  @impl true
  def spec do
    function("reverse_text", "Reverse the characters in a piece of text.", %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "The text to reverse."}
      },
      "required" => ["text"]
    })
  end

  @impl true
  def run(%{"text" => text}, _ctx) do
    {:ok, String.reverse(text)}
  end

  def run(_args, _ctx), do: {:error, "missing 'text'"}
end
```

La segunda cláusula de `run/2` es buena práctica: si el modelo omite un
argumento obligatorio, devuelve un error claro en vez de fallar (un fallo
también se captura, pero un mensaje a medida ayuda al modelo a recuperarse en
la siguiente vuelta).

**`ctx`**, el segundo argumento de `run/2`, lleva la ejecución actual:
`ctx[:agent]` (el agente en ejecución, por ejemplo `%{name: "assistant"}`),
`ctx[:session_key]` (la conversación en vivo, ausente en ejecuciones de un
solo turno), `ctx[:cwd]` (el directorio de trabajo). Trata cada clave como
opcional. Las herramientas que leen/escriben archivos resuelven rutas con
`Pepe.Agent.Workspace`; las que llaman a una API externa suelen ignorar `ctx`
por completo y usar directamente el cliente HTTP `Req` ya incluido, sin
dependencia extra.

## El comportamiento Channel provider

Un proveedor de canal le enseña a Pepe a hablar una nueva plataforma de
mensajería sobre el webhook de entrada genérico ya existente: ninguna ruta
nueva, solo un módulo nuevo en el registro.

```elixir
@callback name() :: String.t()
@callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error
@callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error
@callback parse(payload :: map()) :: {:ok, [inbound]} | :ignore
@callback deliver(config :: map(), to :: String.t(), text :: String.t()) :: :ok | {:error, term()}
```

| Callback | ¿Obligatorio? | Propósito |
|---|---|---|
| `name/0` | sí | Clave de registro y el segmento `:provider` de la URL del webhook, ej. `"whatsapp"`. |
| `verify/2` | sí | Responde el handshake `GET` de la plataforma cuando registras la URL del webhook. `{:ok, challenge}` o `:error` si el proveedor no tiene uno. |
| `authenticate/3` | sí | Comprueba la firma de un `POST` entrante contra el secreto de la conexión. `:ok` para aceptar, `:error` para descartarlo. |
| `parse/1` | sí | Normaliza un payload decodificado en cero o más mensajes `%{from, text, id}`, o `:ignore` para lo que no tiene nada que hacer (recibos, actualizaciones de estado). |
| `deliver/3` | sí | Envía una respuesta de texto a `to` (una dirección del proveedor: número de teléfono, id de canal, ...). |
| `label/0` | no | Etiqueta humana para el panel (usa `name/0` por defecto). |
| `config_schema/0` | no | Campos que el panel renderiza para configurar una conexión: la misma forma que el array `config` de un manifiesto de plugin (abajo). |
| `respond/3` | no | Una respuesta HTTP **síncrona** al `POST` sin procesar, para protocolos que necesitan una antes de cualquier trabajo del agente (el desafío de verificación de URL de Slack, el `PING` de Discord). `{:reply, status, content_type, body}` o `:cont` para caer en `parse/1`. |
| `deliver_file/4` | no | Envía un archivo como adjunto. Omítelo y `send_file` simplemente reporta que el canal no recibe archivos. |
| `addressed?/2` | no | ¿Este payload se dirige al bot, así que debería recibir respuesta? Permite que un proveedor honre `require_mention` en grupos (por defecto cuando se omite: siempre dirigido). |

## El registro

`Pepe.Tools.all/0` devuelve las herramientas integradas seguidas de cada
herramienta de plugin cargada; `Pepe.Webhooks` hace lo mismo con los
proveedores de canal. Una regla para recordar: una integrada siempre gana una
colisión de nombre, así que elige un nombre de herramienta distinto de
`read_file`, `web_search` y el resto de `pepe tools`.

### Conceder una herramienta a un agente

Instalar un plugin no entrega sus herramientas a todos los agentes: solo las
herramientas listadas en un agente quedan expuestas a él, con el mismo
control que una integrada.

**CLI:** `pepe agent add assistant --tools reverse_text,web_search,read_file`

**Panel:** abre el agente en Agentes y marca la herramienta. Las
herramientas de plugin aparecen junto a las integradas.

**Por chat:** un agente con `enable_tool` puede activar una herramienta para
sí mismo:

> Tú: activa la herramienta reverse_text
>
> Agente: reverse_text activada; ya puedes usarla desde tu próximo mensaje

Para conceder una herramienta a un agente *distinto*, la acción `add_tool` de
`manage_agent` lo hace (limitada a los agentes que quien pide tiene permiso
de gestionar, y confirma contigo antes):

> Tú: dale al agente de soporte la herramienta gmail_search
>
> Agente: Voy a añadir gmail_search al agente "support". ¿Confirmas?

## Dónde viven los plugins y cómo se cargan

Los plugins viven en `~/.pepe/plugins/` (sigue `PEPE_HOME`). Pepe recorre esa
carpeta de forma recursiva buscando archivos `.exs`, compila cada uno una vez
y solo recompila cuando cambia su fecha de modificación: suelta un archivo y
funciona sin reiniciar; edítalo y el cambio se aplica en la siguiente llamada
a herramienta. Un archivo puede definir varios módulos (el ejemplo de Google
de abajo trae cuatro).

Un plugin tiene una de dos formas: un archivo `.exs` suelto, o un
**paquete**: un directorio con un `manifest.json` y uno o más archivos
`.exs`.

## Instalar un plugin

La fuente es un archivo local, un directorio local, un `.tar.gz`, o una URL a
cualquiera de esos. Una URL de repositorio de GitHub se descarga como su
archivo fuente (`main`, luego `master`, cuando no se indica ninguna rama).

**CLI:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin list
pepe plugin remove google
```

**Panel:** la página de Plugins acepta una URL de GitHub, una URL `.tar.gz` o
una ruta local; marcas una casilla confirmando que confías en la fuente y
pulsas Instalar. Los plugins instalados se listan con un botón Eliminar y,
cuando el plugin declara ajustes, un botón Configurar.

**Por chat, con `manage_plugin`:** un agente con esta herramienta puede
instalar en tu nombre: haz `scan` de una fuente primero para ver qué hace,
luego `install`, `list`, `remove`. Pasa por el mismo escaneo de seguridad que
la CLI, pero sin la salida de emergencia `--force`: un veredicto peligroso
siempre se rechaza desde el chat, y el agente te dirá que revises el código y
ejecutes `--force` tú mismo en una terminal si aun así lo quieres.

## El escaneo de seguridad

Un plugin es Elixir corriente con acceso total a la aplicación en ejecución:
instalar uno es una decisión de confianza, igual que añadir cualquier
dependencia. Antes de colocarlo en disco, `Pepe.Skills.Sentinel` lo escanea
de forma estática, leyendo el árbol de sintaxis en busca de patrones
peligrosos (lanzar shells, eval dinámico, llamadas destructivas al sistema de
archivos, lectura de secretos, acceso a red). Nunca ejecuta el código, y
devuelve uno de tres veredictos:

- **limpio**: sin hallazgos.
- **precaución**: señalado pero a menudo legítimo (un plugin de canal
  *debería* hacer llamadas de red); se muestra, no bloquea.
- **peligro**: ninguna buena razón para estar ahí; bloquea la instalación.

```bash
pepe plugin scan ./my_plugin.exs        # escanea sin instalar
pepe plugin install ./risky.exs --force # continúa de todos modos, tras revisarlo
```

<div class="note"><strong>Un plugin se ejecuta con acceso total.</strong> El
escaneo es una red de seguridad, no un sustituto de leer el código tú
mismo.</div>

## El manifiesto y el diálogo de Configurar

El `manifest.json` de un paquete lo nombra, lo describe y (lo más útil)
declara los ajustes que necesita. Del ejemplo de Google incluido:

```json
{
  "name": "google",
  "version": "0.1.0",
  "description": "Google Workspace tools: read/create Calendar events and search/send Gmail, as agent tools.",
  "provides": ["tool:gcal_upcoming", "tool:gcal_create_event", "tool:gmail_search", "tool:gmail_send"],
  "files": ["google.exs"],
  "config": [
    {"key": "access_token", "label": "Access token", "type": "secret", "hint": "ya29... (expires in ~1h); or fill the refresh trio below. Store as ${ENV_VAR} to keep it out of the file."},
    {"key": "client_id", "label": "OAuth client ID", "type": "text", "hint": "...apps.googleusercontent.com"},
    {"key": "client_secret", "label": "OAuth client secret", "type": "secret"},
    {"key": "refresh_token", "label": "Refresh token", "type": "secret", "hint": "minted once from the consent flow; survives access-token expiry"}
  ]
}
```

Cada entrada de `config` es un campo: `key` (el nombre que lee tu código),
`label` (mostrado en el formulario), `type` (`"text"`, `"secret"` para una
entrada enmascarada, o `"select"` con una lista `"options"`), y un `hint`
opcional. El panel lee este array y renderiza el diálogo de Configurar. Un
plugin nuevo no necesita pantalla nueva. Un valor puede ser una referencia
`${ENV_VAR}`, guardada tal cual y resuelta desde el entorno solo al leerla,
así que los secretos nunca quedan expandidos en el archivo de configuración.

Lee un ajuste guardado desde el código de tu plugin con
`Pepe.Plugins.config/3` (el nombre es el nombre del paquete en el manifiesto;
el tercer argumento es un valor por defecto):

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

Un patrón común: prefiere el valor del panel, recurre a una variable de
entorno, para que el plugin funcione tanto si el operador rellena el
formulario como si exporta una variable (el ejemplo de Google de abajo hace
exactamente eso).

## Ejemplo: el plugin de herramientas Google Workspace

`examples/plugins/google/google.exs` trae cuatro herramientas en un solo
archivo:

| Herramienta | Qué hace |
|------|--------------|
| `gcal_upcoming` | Lista los próximos eventos del Google Calendar principal |
| `gcal_create_event` | Crea un evento (resumen, inicio, fin, descripción) |
| `gmail_search` | Busca en Gmail y devuelve remitente y asunto de las coincidencias |
| `gmail_send` | Envía un correo en texto plano |

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

Se autentica con un token bearer OAuth2 resuelto en el momento de la llamada
- nada sensible embebido en el código. Exporta un token de acceso listo (más
rápido, expira en ~1h):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

o un refresh token (sobrevive a la expiración; el plugin genera un token de
acceso por llamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Consigue estos valores creando un cliente OAuth (tipo "Desktop app") en un
proyecto de Google Cloud, con las API de Calendar y Gmail habilitadas, tras
ejecutar el flujo de consentimiento una vez para los ámbitos que uses. O
rellena los mismos campos en el diálogo de Configurar del plugin, guardando
los secretos como referencias `${ENV_VAR}`.

El código completo de una de las herramientas, mostrando el patrón de
principio a fin:

```elixir
defmodule Pepe.Plugins.GCalUpcoming do
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]
  alias Pepe.Plugins.Google.API

  @impl true
  def name, do: "gcal_upcoming"

  @impl true
  def spec do
    function("gcal_upcoming", "List upcoming events on the user's primary Google Calendar.", %{
      "type" => "object",
      "properties" => %{
        "max" => %{"type" => "integer", "description" => "How many events to return (default 10)."}
      }
    })
  end

  @impl true
  def run(args, _ctx) do
    max = args["max"] || 10
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    API.with_token(fn token ->
      params = [maxResults: max, orderBy: "startTime", singleEvents: true, timeMin: now]

      case API.get("https://www.googleapis.com/calendar/v3/calendars/primary/events", token, params) do
        {:ok, %{"items" => items}} -> {:ok, format_events(items)}
        {:ok, _} -> {:ok, "No upcoming events."}
        error -> error
      end
    end)
  end
end
```

> Tú: ¿Qué tengo mañana en el calendario? Envía un resumen por correo a sam@example.com
>
> Agente: (invoca gcal_upcoming, luego gmail_send) Tienes 3 eventos mañana. Envié el resumen por correo a sam@example.com.

## Ejemplo: el plugin de canal Chatwoot

`examples/plugins/chatwoot/` muestra la otra forma: un **canal**, no una
herramienta. Registra un proveedor `chatwoot` para que Pepe se siente detrás
de una bandeja de [Chatwoot](https://www.chatwoot.com) como el agente de IA,
en todos los canales que Chatwoot ya cubre (WhatsApp, widget web, Instagram,
...).

```bash
pepe plugin install ./examples/plugins/chatwoot
```

**Traspaso nativo a un humano, sin pegamento extra.** Chatwoot lleva la señal
de traspaso en cada webhook: el `status` de la conversación. El plugin
implementa `parse/1` para responder solo conversaciones marcadas `pending`
(propiedad del bot); en el momento en que un agente humano la toma (`open`),
Pepe se calla, y retoma cuando vuelve a `pending`.

**Configuración, en Chatwoot:** crea un AgentBot, apunta su webhook saliente
a `https://TU_HOST/webhooks/<company>/chatwoot/<slug>`. La conexión guarda
`base_url`, `account_id` y un `api_token` (como `${ENV_VAR}`) vía
`config_schema/0`, rellenados desde el panel, el mismo patrón de Configurar
que cualquier plugin.

> Esta es una de dos formas mutuamente excluyentes de operar WhatsApp:
> **o bien** WhatsApp directo en Pepe (el proveedor integrado `whatsapp`)
> **o bien** WhatsApp en Chatwoot con Pepe detrás (este plugin). Nunca
> conectes el mismo número a ambos.

## Entregar un archivo, no solo texto

El `run/2` de una herramienta solo devuelve texto. Para entregar un archivo
real (una hoja de cálculo, un PDF) a la persona en la conversación, no
reinventes la entrega: invoca la herramienta integrada `send_file` con una
ruta; Pepe resuelve el canal a partir de la sesión y lo entrega ahí. Concede
`send_file` a un agente y simplemente funciona desde el chat, en cualquier
canal cuyo proveedor implemente `deliver_file/4`.

## Checklist

**Escribir una herramienta:**

1. Implementa `name/0`, `spec/0`, `run/2`; dale un nombre distinto de toda
   integrada.
2. Devuelve `{:ok, text}` / `{:error, message}` desde `run/2`, escrito para
   que el modelo lo lea.
3. ¿Necesita credenciales u opciones? Incluye un `manifest.json` con un array
   `config`, léelas con `Pepe.Plugins.config/3`.

**Escribir un canal:**

1. Implementa `name/0`, `verify/2`, `authenticate/3`, `parse/1`, `deliver/3`;
   añade `config_schema/0` si necesita credenciales configuradas desde el
   panel.
2. Añade `respond/3` solo si el protocolo de la plataforma exige una
   respuesta síncrona antes de cualquier trabajo del agente; `deliver_file/4`
   solo si puede recibir adjuntos.

**En cualquier caso:** escanéalo (`pepe plugin scan SRC` o `manage_plugin
scan`), instálalo, revisa lo que encontró el escaneo, y luego concede la
herramienta a un agente (CLI, panel, o `enable_tool`/`manage_agent` desde el
chat). Un canal no necesita concesión, queda activo en cuanto se instala.
