---
title: Plugins
description: Extiende Pepe con tus propias herramientas (y canales) en tiempo de ejecucion colocando un archivo Elixir en la carpeta de plugins. Sin recompilar, sin tocar el nucleo.
---

Pepe viene con un conjunto de herramientas integradas: ejecutar un comando de
shell, leer y escribir archivos, obtener una URL, buscar en la web, enviar un
archivo al chat actual y mas. Un plugin te permite anadir las tuyas sin tocar el
nucleo ni recompilar la aplicacion. Coloca un archivo en la carpeta de plugins y
funciona en la siguiente llamada a una herramienta.

Un plugin puede anadir dos tipos de cosas:

- Una **herramienta**. Un modulo pequeno que el modelo puede invocar durante el
  bucle del agente. Es el caso comun y el foco de esta pagina.
- Un **proveedor de canal**. Un modulo que le ensena a Pepe a hablar con una
  nueva plataforma de mensajeria a traves del webhook de entrada generico. El
  mismo cargador, una forma distinta.

## Como funciona una herramienta

Un agente ejecuta un bucle. Llama al modelo, el modelo puede pedir invocar una o
mas herramientas, Pepe las ejecuta, devuelve los resultados y repite hasta que el
modelo entrega una respuesta final. Una herramienta es una funcion con nombre que
el modelo tiene permitido invocar. La describes con una especificacion JSON
(nombre, descripcion, parametros) para que el modelo sepa cuando y como
invocarla, y tu aportas el codigo que se ejecuta cuando lo hace.

Cada herramienta, integrada o de plugin, implementa el mismo contrato de tres
funciones.

### El comportamiento Tool

```elixir
@callback name() :: String.t()
@callback spec() :: map()
@callback run(args :: map(), ctx :: map()) ::
            {:ok, String.t()} | {:error, String.t()}
```

- `name/0` es el nombre de funcion que el modelo invoca, por ejemplo
  `"read_file"`. Debe ser unico entre todas las herramientas.
- `spec/0` devuelve la especificacion de funcion al estilo de OpenAI: un nombre,
  una descripcion en lenguaje llano y un JSON Schema para los parametros. El
  modelo lo lee para decidir cuando invocar la herramienta y que argumentos
  pasar.
- `run/2` recibe los `args` decodificados (un mapa simple con claves de tipo
  cadena, ya parseados desde el JSON del modelo) y un mapa `ctx` con informacion
  sobre la ejecucion actual. Devuelve `{:ok, text}` si tiene exito o
  `{:error, message}` si falla. En cualquier caso el resultado se convierte en
  una cadena y se devuelve al modelo como respuesta de la herramienta, asi que
  escribelo para que el modelo lo lea.

Un ayudante, `Pepe.Tools.Tool.function/3`, construye por ti el sobre estandar de
la especificacion, de modo que solo rellenas el nombre, la descripcion y los
parametros.

### Una herramienta minima

Aqui tienes una herramienta completa y funcional que invierte una cadena.
Guardala como un archivo `.exs` e instalala (mas abajo).

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

Ese es todo el patron. La segunda clausula de `run/2` es un buen habito. Si el
modelo invoca la herramienta sin el argumento requerido, devuelves un error claro
en lugar de que se produzca un fallo. Un fallo tambien se captura y se reporta,
pero un mensaje a medida ayuda al modelo a recuperarse en el siguiente turno.

### Que hay en ctx

El mapa `ctx` lleva el contexto de la ejecucion actual. Las claves que es mas
probable que uses:

- `ctx[:agent]` es el agente que esta ejecutandose, por ejemplo
  `%{name: "assistant"}`.
- `ctx[:session_key]` identifica la conversacion en vivo cuando la hay (un chat
  en un canal de mensajeria, una sesion WebSocket). Esta ausente en las
  ejecuciones de un solo turno.
- `ctx[:cwd]` es el directorio de trabajo de la ejecucion.

Las herramientas que leen o escriben archivos usan `Pepe.Agent.Workspace` para
resolver rutas contra el espacio de trabajo persistente del agente. Las
herramientas que hablan con el mundo exterior (una API HTTP, una base de datos)
suelen ignorar `ctx` por completo. Trata cada clave como opcional y compara de
forma defensiva.

<div class="note"><strong>Usa el Req incluido para HTTP.</strong> Pepe ya
depende del cliente HTTP Req, asi que tu plugin puede llamar a cualquier API web
sin una dependencia extra. Mira como lo hacen la herramienta integrada
<code>web_search</code> y el ejemplo de Google mas abajo.</div>

## El registro: como se encuentran las herramientas

`Pepe.Tools` es el registro unico. Combina dos fuentes.

- El conjunto **integrado**, una lista fija en `Pepe.Tools`. Incluye `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file` y las herramientas de gestion que un
  agente usa para operar el runtime por chat (`manage_agent`, `manage_channel`,
  `enable_tool`, `schedule_task` y otras).
- Los **plugins**, descubiertos en tiempo de ejecucion desde la carpeta de
  plugins.

`Pepe.Tools.all/0` devuelve las integradas seguidas de cada herramienta de plugin
cargada. Cuando listas las herramientas de un agente, cada nombre se busca aqui.
Hay una regla que conviene conocer: ante una colision de nombres, gana la
integrada. No puedes eclipsar `read_file` con un plugin del mismo nombre, asi que
elige un nombre distinto para tu herramienta.

### Conceder una herramienta a un agente

Que un plugin este instalado no entrega automaticamente sus herramientas a cada
agente. Solo las herramientas que listas en un agente quedan expuestas a el, y
cada llamada sigue pasando por la misma puerta de permisos que una herramienta
integrada. Concedes una herramienta de tres maneras.

**Con la CLI de pepe.** Lista la herramienta en el `--tools` del agente:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**En el panel.** Abre el agente en Agentes y marca la herramienta en su lista de
herramientas. Las herramientas del plugin aparecen junto a las integradas.

#### Hazlo por chat

Un agente que tiene la herramienta integrada `enable_tool` puede activar una
herramienta para si mismo despues de que instales un plugin, sin que toques la
CLI ni el panel.

> Tu: activa la herramienta reverse_text
>
> Agente: reverse_text activada; puedes usarla desde tu proximo mensaje

`enable_tool` solo acepta una herramienta que ya exista como integrada o como
plugin cargado, y el cambio surte efecto en el proximo mensaje del agente. Para
conceder una herramienta a un agente *distinto*, un agente con la herramienta
`manage_agent` puede hacerlo con la accion `add_tool`. Esa herramienta esta
limitada a los agentes que el agente que actua tiene permitido gestionar, y sus
instrucciones le indican confirmar el cambio contigo antes de aplicarlo.

> Tu: dale al agente de soporte la herramienta gmail_search
>
> Agente: Voy a anadir gmail_search al agente "support". Confirmas?
>
> Tu: si
>
> Agente: gmail_search anadida a support.

## Donde viven los plugins y como se cargan

Los plugins viven bajo `~/.pepe/plugins/` (la carpeta base sigue a `PEPE_HOME` si
lo defines). Pepe escanea esa carpeta de forma recursiva en busca de archivos
`.exs`, compila cada uno una vez y lo cachea. Cuando cambia la fecha de
modificacion de un archivo, se recompila en la siguiente llamada. Coloca un
archivo y funciona sin reiniciar. Editalo y el cambio surte efecto en la
siguiente llamada a una herramienta.

Cada modulo cargado se compara contra la forma que un consumidor espera. Un
modulo que exporta `name/0`, `spec/0` y `run/2` se trata como una herramienta. Un
modulo que exporta `name/0` mas los callbacks de proveedor de canal se trata como
un canal. Un archivo puede definir varios modulos, asi que un unico plugin puede
traer un punado de herramientas relacionadas (el ejemplo de Google trae cuatro).

## Instalar un plugin

La fuente puede ser un archivo local, un directorio local, un archivo comprimido
o una URL a cualquiera de esos. La URL de un repositorio de GitHub se obtiene como
su archivo de codigo fuente (cuando no se indica rama, se prueba `main` y luego
`master`).

**Con la CLI de pepe:**

```bash
pepe plugin install ./my_plugin.exs
pepe plugin install ./examples/plugins/google
pepe plugin install https://github.com/you/pepe-myplugin
pepe plugin install https://example.com/pepe-myplugin.tar.gz
```

Lista lo instalado y elimina por nombre:

```bash
pepe plugin list
pepe plugin remove google
```

**En el panel.** La pagina de Plugins tiene un campo de instalacion que acepta la
URL de un repositorio de GitHub, una URL `.tar.gz` o una ruta local. Marcas una
casilla confirmando que confias en la fuente y luego pulsas Instalar. Los plugins
instalados se listan con un boton de Eliminar y, cuando el plugin declara
ajustes, un boton de Configurar (ver mas abajo).

Un archivo `.exs` suelto se copia directamente a la carpeta de plugins. Un
**paquete** se copia como carpeta. Un paquete es un directorio que contiene un
`manifest.json` y uno o mas archivos `.exs`.

## El analisis de seguridad

Un plugin es Elixir corriente con acceso total a la aplicacion en ejecucion.
Instalar uno es una decision de confianza, igual que anadir cualquier
dependencia. Para que esa decision sea informada, Pepe analiza el codigo de forma
estatica antes de colocarlo en disco. El analisis lee el arbol de sintaxis
buscando patrones peligrosos (lanzar shells, llamadas de red, ofuscacion, leer
secretos). Nunca ejecuta el codigo y devuelve uno de tres veredictos: limpio,
precaucion o peligro.

Un veredicto de peligro bloquea la instalacion. Puedes continuar de todas formas,
tras revisar el codigo, pasando `--force` en la CLI (o el boton "Instalar de
todos modos" en el panel, que aparece solo tras un veredicto de peligro):

```bash
pepe plugin install ./risky_plugin.exs --force
```

Tambien puedes analizar una fuente sin instalarla:

```bash
pepe plugin scan ./my_plugin.exs
```

<div class="note"><strong>Un plugin se ejecuta con acceso total.</strong> Es
codigo de nivel administrador. Instala solo desde una fuente que conozcas y en la
que confies, y leelo primero. El analisis es una red de seguridad, no un
sustituto de la revision.</div>

## El manifiesto y el dialogo de Configurar

Un paquete puede llevar un `manifest.json`. Nombra el paquete, lo describe, lista
lo que provee y, lo mas util, declara los ajustes que necesita. Aqui esta el
manifiesto del ejemplo de Google:

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

El array `config` es la parte interesante. Cada entrada describe un campo:

- `key` es el nombre del ajuste que lee tu codigo.
- `label` es la etiqueta humana que se muestra en el formulario.
- `type` es `"text"`, `"secret"` (entrada enmascarada) o `"select"` (anade una
  lista `"options"`).
- `hint` es texto de ayuda opcional que se muestra bajo el campo.

El panel lee este array y renderiza un dialogo de Configurar para el plugin, asi
que un plugin nuevo no necesita una pantalla nueva. Un valor que introduces puede
ser una referencia `${ENV_VAR}`. Se guarda como la referencia literal y se
resuelve desde el entorno solo al leerlo, de modo que los secretos nunca quedan
expandidos en el archivo de configuracion.

### Leer tus ajustes desde el codigo

Dentro del plugin, lee un ajuste guardado con `Pepe.Plugins.config/3`. Devuelve
el valor guardado con cualquier referencia `${ENV_VAR}` ya resuelta, o el valor
por defecto cuando no esta definido:

```elixir
token = Pepe.Plugins.config("google", "access_token")
region = Pepe.Plugins.config("myplugin", "region", "us-east-1")
```

El primer argumento es el nombre del plugin (el nombre del paquete del
manifiesto). Este es el puente desde el formulario del panel hasta tu codigo en
ejecucion. Un patron comun es preferir el valor del panel y recurrir a una
variable de entorno, de modo que el plugin funcione tanto si el operador rellena
el formulario como si exporta una variable.

## Enviar un archivo de vuelta al chat

Las herramientas devuelven texto al modelo. Cuando quieres entregar un archivo
real a la persona en la conversacion (una hoja de calculo, un PDF, una imagen),
lo hace la herramienta integrada `send_file`. Tu agente produce el archivo como
prefiera, por ejemplo un comando `bash` que consulta una base de datos y escribe
un `.xlsx`, y luego invoca `send_file` con la ruta. Pepe averigua en que canal
esta la conversacion a partir de la sesion y entrega el archivo alli, asi que el
agente nunca necesita saber ids de chat ni tokens.

`send_file` toma una `path` (absoluta, o relativa al directorio de trabajo de la
ejecucion) y un `caption` opcional. Funciona en cualquier canal cuyo proveedor
admita adjuntos (Telegram, WhatsApp, Slack, Discord y otros). Si el canal no
puede recibir archivos, o la ejecucion no es un chat en vivo, la herramienta lo
reporta con claridad al modelo. Como es integrada, lo tienes gratis: basta con
conceder la herramienta `send_file` al agente.

Esto tambien es una capacidad de chat. Un agente que tiene `send_file` la usara
cuando le pidas un archivo en la conversacion.

> Tu: exporta los pedidos del mes pasado como hoja de calculo y enviamela aqui
>
> Agente: (ejecuta una consulta, escribe orders.xlsx, invoca send_file) Envie orders.xlsx a la conversacion.

## Ejemplo: el plugin de Google Workspace

Pepe incluye un ejemplo completo de plugin bajo `examples/plugins/google`. Un
unico archivo `google.exs` define cuatro herramientas:

| Herramienta | Que hace |
|------|--------------|
| `gcal_upcoming` | Lista los proximos eventos del Google Calendar principal |
| `gcal_create_event` | Crea un evento (resumen, inicio, fin, descripcion) |
| `gmail_search` | Busca en Gmail y devuelve remitente y asunto de las coincidencias |
| `gmail_send` | Envia un correo de texto plano |

Instalalo y concede las herramientas a un agente:

```bash
pepe plugin install ./examples/plugins/google
pepe agent add assistant --tools gcal_upcoming,gcal_create_event,gmail_search,gmail_send
```

El plugin muestra todo el patron en un solo archivo: varios modulos de
herramienta que cada uno implementa el comportamiento, un pequeno modulo ayudante
compartido para la autenticacion y el HTTP, y un manifiesto que impulsa el
dialogo de Configurar.

### Como se autentica

Las APIs de Google usan tokens bearer OAuth2. El plugin resuelve un token en el
momento de la llamada, asi que nada sensible queda incrustado en el codigo. Lee
sus ajustes primero desde la configuracion del panel y recurre a variables de
entorno, lo que significa que funciona tanto si rellenas el formulario de
Configurar como si exportas variables. Hay dos maneras de aportar credenciales.

**A. Un token de acceso listo** (lo mas rapido; expira en aproximadamente una
hora):

```bash
export GOOGLE_ACCESS_TOKEN=ya29....
```

**B. Un refresh token** (sobrevive a la expiracion; el plugin acuna un token de
acceso por llamada):

```bash
export GOOGLE_CLIENT_ID=...apps.googleusercontent.com
export GOOGLE_CLIENT_SECRET=...
export GOOGLE_REFRESH_TOKEN=...
```

Para obtenerlos, crea un cliente OAuth (tipo "Desktop app") en un proyecto de
Google Cloud, habilita las APIs de Calendar y Gmail, y ejecuta el flujo de
consentimiento una vez para los scopes que uses
(`https://www.googleapis.com/auth/calendar` y
`https://www.googleapis.com/auth/gmail.modify`). Tambien puedes introducir los
mismos valores en el dialogo de Configurar del plugin en el panel, guardando los
secretos como referencias `${ENV_VAR}` para mantenerlos fuera del archivo.

Aqui esta la forma de una de las herramientas, para que veas el patron de la API
de principio a fin:

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

Una vez concedidas las herramientas y establecidas las credenciales, el agente
las usa en conversacion normal.

> Tu: que tengo en el calendario manana, y envia un resumen por correo a sam@example.com
>
> Agente: (invoca gcal_upcoming, luego gmail_send) Tienes 3 eventos manana. Envie el resumen por correo a sam@example.com.

## Proveedores de canal, en breve

El mismo cargador impulsa los canales de mensajeria. Un plugin de canal es un
modulo que exporta `name/0` mas los callbacks de proveedor del webhook de entrada
(`verify`, `authenticate`, `parse`, `deliver` y, opcionalmente, `respond`,
`deliver_file` y un `config_schema` para su propio dialogo de Configurar). Una
vez instalado, el proveedor queda accesible en la ruta del webhook de entrada
generico sin anadir una nueva URL, y aparece entre los proveedores de canal en
`pepe plugin list`. El ejemplo incluido de Chatwoot bajo
`examples/plugins/chatwoot` ejecuta Pepe detras de una bandeja de Chatwoot con
traspaso nativo a un humano. La pagina de canales de mensajeria cubre el contrato
del proveedor por completo.

## Lista de verificacion para escribir tu propia herramienta

1. Escribe un modulo que implemente `name/0`, `spec/0` y `run/2`.
2. Dale un nombre unico (las integradas ganan una colision, asi que evita sus
   nombres).
3. Devuelve `{:ok, text}` o `{:error, message}` desde `run/2`, escrito para que
   el modelo lo lea.
4. Si necesita credenciales u opciones, incluye un `manifest.json` con un array
   `config` y leelas con `Pepe.Plugins.config/3`.
5. Instala con `pepe plugin install`, revisa el analisis y concede la herramienta
   a un agente (CLI, panel o por chat con `enable_tool`).
