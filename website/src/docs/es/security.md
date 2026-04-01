---
title: Seguridad y entorno aislado
description: Los agentes ejecutan codigo, asi que hacen trabajo real y pueden causar dano real. Pepe apila una barrera de permisos, protecciones de comandos, un entorno aislado opcional, referencias a secretos, hooks de censura y control de acceso, y es honesto sobre lo que hace cada uno.
---

## La amenaza, sin rodeos

Un agente que puede ejecutar un comando o escribir un archivo es util precisamente porque actua sobre tu maquina. Ese mismo poder es el riesgo. Pepe no finge que un solo ajuste vuelva esto seguro. En cambio apila varias protecciones independientes, cada una con una tarea clara, y te deja subir la intensidad a medida que crece tu exposicion. Esta pagina recorre cada capa, desde la que siempre esta activa hasta la que activas tu mismo para poner un limite firme.

Las capas, de la mas debil pero siempre activa a la mas fuerte pero opcional:

1. La barrera de permisos. Una persona aprueba cualquier herramienta que actue.
2. Protecciones de comandos. Un filtro incorporado que rechaza unos pocos comandos catastroficos.
3. El entorno aislado. Un envoltorio opcional que ejecuta comandos de shell en aislamiento real.
4. Referencias a secretos. Las credenciales viven como `${ENV_VAR}`, nunca expandidas en disco.
5. Hooks de censura. Limpieza opcional de datos personales antes de que el texto llegue a un modelo.
6. Control de acceso. La contrasena del panel y los tokens de portador de la API.

<div class="note"><strong>Ningun ajuste por si solo es un limite de seguridad.</strong> El valor por defecto honesto es la barrera de permisos mas las protecciones. Para cualquier cosa que corra sin supervision o apruebe herramientas de forma automatica, agrega el entorno aislado, y lo ideal es ejecutar Pepe como un usuario limitado o dentro de un contenedor.</div>

## La barrera de permisos

Cada llamada a una herramienta pasa por una barrera antes de ejecutarse. Las herramientas de solo lectura corren libremente. Todo lo que actua (ejecutar un comando, escribir o mover un archivo, cambiar la configuracion, y cualquier herramienta de plugin de terceros) debe autorizarse primero.

Las herramientas que nunca preguntan son las de solo lectura: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` y `send_to_agent`. Cualquier cosa que no este en esa lista, incluida cualquier herramienta de plugin agregada, se trata como riesgosa y requiere aprobacion. Es un valor por defecto deliberadamente seguro: se asume que una herramienta desconocida es peligrosa.

Cuando una herramienta riesgosa no ha sido aprobada de antemano, el runtime pregunta a la persona al otro lado. Cada superficie muestra ese aviso a su manera nativa (botones en linea en un canal de chat, un menu con flechas del teclado en la CLI), pero la decision siempre es una de cuatro:

- `once`: permite solo esta llamada, pregunta de nuevo la proxima vez.
- `session`: permite durante el resto de esta conversacion. Se guarda en memoria y se olvida cuando inicias una nueva sesion o reinicias. Las demas sesiones siguen preguntando.
- `always`: permite de ahora en adelante. Se guarda en el agente en `config.json`.
- `deny`: rechaza. Nunca se recuerda, asi que la misma llamada se pregunta otra vez mas adelante.

Una llamada denegada no hace fallar la ejecucion. Se le informa al modelo que la persona no autorizo la herramienta y se le pide que pruebe otro enfoque o que te consulte, de modo que la conversacion continua.

### Aprobacion automatica y el agente propietario

Elegir `always` en el aviso registra esa herramienta en la lista `auto_approve` del agente, asi que nunca vuelve a preguntar para ese agente. No hay una opcion aparte para configurar esto por adelantado desde `pepe agent add`. Otorgas confianza respondiendo `always` una vez cuando aparece el aviso, o editando el agente en `config.json`:

```json
{
  "agents": {
    "ops": {
      "system_prompt": "You keep the build green.",
      "tools": ["bash", "read_file", "write_file"],
      "auto_approve": ["read_file", "write_file"]
    }
  }
}
```

Un unico comodin `"*"` en `auto_approve` significa que el agente ejecuta cualquier herramienta sin preguntar jamas. Ese es el agente propietario omnipotente que se crea para ti en `pepe setup`: con confianza sobre todas las herramientas para que puedas manejar tu propia maquina sin friccion. Otorga esa confianza de forma deliberada, y nunca a un agente expuesto a entradas no confiables.

```json
{
  "agents": {
    "owner": {
      "system_prompt": "...",
      "tools": ["bash", "read_file", "write_file", "edit_file"],
      "auto_approve": ["*"]
    }
  }
}
```

<div class="note"><strong>Las superficies sin persona corren libremente.</strong> La API HTTP no tiene a quien preguntar, asi que no aporta ningun aprobador y las herramientas riesgosas corren sin preguntar. Trata la API como de plena confianza, y protegela con un token (ver mas abajo) antes de exponerla.</div>

### El propietario puede manejar la CLI por chat

La herramienta `manage_pepe` ejecuta los mismos comandos `pepe` no interactivos que escribirias en una terminal (agregar un modelo, definir un agente, acuñar un token, programar una tarea, administrar empresas), asi que un agente propietario de confianza puede operar todo el runtime desde una conversacion.

> Tu: Agrega un agente llamado researcher con las herramientas web_search y read_file.
>
> Agente: (te pide que confirmes, luego ejecuta `pepe agent add researcher --tools web_search,read_file`) Listo. El agente researcher esta preparado.

Es la herramienta mas poderosa que existe. Otorgala solo a un agente propietario en el que confies plenamente, nunca a uno expuesto a entradas no confiables. Como toda herramienta que actua, pasa por la barrera de permisos, y los comandos interactivos o de larga duracion (`setup`, `chat`, `serve` y las pasarelas en primer plano) se rechazan porque no pueden correr como una sola ejecucion. Para una tarea unica y mas acotada, prefiere las herramientas enfocadas: `manage_token` para tokens, `manage_channel` para canales, `schedule_task` para tareas programadas.

## Protecciones de comandos

Las herramientas de shell (`bash` y `run_script`) pasan cada comando por una guardia primero. La guardia rechaza un conjunto pequeno y deliberadamente estrecho de operaciones catastroficas que nunca son legitimas:

- Borrados recursivos de una ruta del sistema, `/`, `~` o `$HOME`.
- Formatear un sistema de archivos (`mkfs`).
- Escribir en crudo o sobrescribir un dispositivo de disco (`dd of=/dev/...`, o redirigir hacia `/dev/sda` y similares).
- Bombas de bifurcacion (fork bombs).
- Apagar o reiniciar el equipo (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

Es pura, multiplataforma, sin configuracion y siempre activa. No cuesta nada, asi que nunca hay que habilitarla.

Ten claro lo que es: una red fina contra accidentes y contra inyeccion de prompts evidente, no un limite de seguridad. Un comando decidido u ofuscado puede escapar a la inspeccion estatica, y la guardia permite a proposito trabajo potente pero legitimo, como instalar dependencias o consultar una base de datos. Para un limite real, agrega el entorno aislado.

## El entorno aislado (aislamiento opcional)

Para un limite de verdad, de modo que ni siquiera un agente con aprobacion automatica pueda tocar el equipo anfitrion, configura un envoltorio de aislamiento. Un envoltorio es un pequeno ejecutable al que Pepe le pasa cada comando. El envoltorio ejecuta el comando aislado segun lo permita el anfitrion, y luego devuelve la salida. Pepe pasa el directorio de trabajo del agente en la variable de entorno `PEPE_SANDBOX_CWD`, para que el envoltorio pueda montar o confinar las escrituras solo a ese directorio.

Cuando no hay envoltorio configurado (el valor por defecto), los comandos corren directamente en el anfitrion y la barrera de permisos es la proteccion. Cuando hay un envoltorio configurado, cada comando de shell pasa por el.

La forma mas rapida de configurar uno es el flujo de instalacion, que escribe un envoltorio listo para usar en `~/.pepe/sandbox/` y apunta la configuracion hacia el:

```bash
pepe setup
```

Elige el paso Sandbox y escoge tu aislamiento. Pepe ofrece lo que tu anfitrion soporta:

| Anfitrion | Opciones |
|------|------|
| Linux | firejail (ligero, espacios de nombres) o Docker/Podman |
| macOS | sandbox-exec (viene con macOS) o Docker Desktop |
| Windows | Docker o WSL |

Docker es el comun denominador portatil: monta solo el espacio de trabajo, asi que el resto del sistema de archivos del anfitrion queda invisible, y puedes mantener la red activa cuando el agente necesita una base de datos o una API. El envoltorio de Docker se ajusta con variables de entorno, incluidas `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` o `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS` y `PEPE_SANDBOX_RUNTIME` (`docker` o `podman`).

Si prefieres apuntar a tu propio envoltorio, define la ruta directamente en `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Cualquier ejecutable sirve mientras corra sus argumentos (`program arg1 arg2 ...`) de forma aislada y respete `PEPE_SANDBOX_CWD`. La instalacion solo advierte, y nunca instala automaticamente, si la herramienta subyacente (docker, firejail, sandbox-exec) falta en tu `PATH`.

<div class="note"><strong>No existe un entorno aislado verdadero, sin configuracion y multiplataforma.</strong> Todo aislamiento real necesita una funcion del sistema operativo o una herramienta externa. Por eso el entorno aislado es opcional y los valores por defecto siempre activos son la barrera mas las protecciones. Cuando los agentes corren sin supervision o aprueban herramientas de forma automatica, trata el entorno aislado como obligatorio, no opcional.</div>

## Los secretos quedan como referencias

La configuracion vive en un archivo JSON plano en `~/.pepe/config.json`. No hay base de datos. Para mantener las credenciales fuera de ese archivo, escribelas como referencias `${ENV_VAR}`. Pepe las interpola contra el entorno al momento de leer y nunca persiste el valor expandido.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini"
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}" }
}
```

En tiempo de ejecucion la clave real se lee del entorno. En disco el archivo solo contiene el marcador. El mismo mecanismo funciona para los tokens de pasarela, los ajustes de plugins y la contrasena del panel, asi que puedes versionar o compartir una configuracion sin filtrar nada. Exporta las variables antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Un marcador de cadena completa que se resuelve en nada (la variable no esta definida) se trata como "sin definir" en lugar de una cadena vacia, asi que un secreto ausente aparece como un claro "no configurado" en vez de un blanco silencioso.

### Hazlo por chat

Un agente al que se le otorgan las herramientas de solo lectura `config_get` y `doctor` puede informar sobre tu configuracion y detectar un secreto ausente en una conversacion normal. Ambas son de solo lectura, asi que nunca activan la barrera de permisos.

> Tu: Esta todo configurado correctamente?
>
> Agente: (ejecuta `doctor`) Encontre un problema: la conexion de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, pero esa variable no esta definida en el entorno. Exportala antes de servir.

La herramienta `doctor` hace un chequeo de salud de toda la configuracion y marca secretos `${ENV}` sin definir, agentes que apuntan a modelos ausentes, programaciones invalidas y conexiones inalcanzables. Pasa `live: true` para tambien sondear la red.

<div class="note"><strong>Los ajustes sensibles a la seguridad no se pueden editar por chat.</strong> La herramienta protegida `config_set` esta cerrada por defecto: solo toca una lista blanca corta (el modelo y el agente por defecto, el idioma, la zona horaria y un par de opciones de Telegram). Los secretos, las listas de herramientas permitidas, los tokens de bot, el envoltorio del entorno aislado y la contrasena del panel quedan a proposito fuera de esa lista, asi que `config_set` no puede cambiarlos. Esos los defines tu con la CLI o el panel. Los tokens de la API son lo unico que un agente puede acuñar por chat, pero solo a traves de la herramienta separada y protegida por la barrera de permisos `manage_token`, nunca mediante `config_set`.</div>

## Hooks de censura (limpieza opcional de datos personales)

Si tus agentes manejan datos personales, puedes limpiarlos antes de que lleguen a un modelo. Los hooks de censura corren sobre el flujo de mensajes y se habilitan por agente, asi que solo los agentes que los necesitan pagan el costo.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Vienen cuatro hooks de fabrica:

- `pii_redact`: un censor de expresiones regulares, sin conexion y sin dependencias. Reemplaza datos personales estructurados (correo, numero de tarjeta e identificaciones nacionales como el CPF o el CNPJ) con un token estable como `[CPF_1]`. Por defecto es reversible: registra `token -> real` para que la tuberia pueda restaurar el valor real en la respuesta de salida.
- `llm_redact`: usa un modelo local o configurado para reemplazar nombres, direcciones y texto libre con seudonimos realistas, y luego los restaura a la salida. Va mejor junto a `pii_redact`, que maneja las identificaciones estructuradas de forma determinista mientras el modelo se ocupa de las partes desordenadas en cualquier idioma.
- `presidio`: envia el texto a traves de tus propios contenedores autoalojados de analisis y anonimizacion de Microsoft Presidio, asi los datos quedan bajo tu control.
- `http_redact`: la valvula de escape generica. Pepe publica el mensaje en tu propio endpoint, que devuelve el texto transformado, asi cualquier servicio de censura se conecta sin un adaptador dedicado.

Los ajustes globales de cada hook (que paquetes de reconocedores, patrones personalizados, si mantenerlo reversible) viven bajo `"hooks"` en `config.json`. Puedes pedirle a un modelo que redacte una configuracion de `pii_redact` por ti:

```bash
pepe hooks list
pepe hooks generate "redact Brazilian CPF, emails, and phone numbers" --save
```

Los hooks de expresiones regulares y de HTTP fallan de forma abierta por diseno: si un censor da error o un modelo no esta disponible, el texto original pasa en lugar de bloquear el trabajo. Cuando necesitas una garantia firme, marca la conexion de modelo con `require_redaction` en `config.json`. Un modelo marcado asi se niega a ejecutarse a menos que el agente tenga al menos un hook de censura habilitado, convirtiendo una limpieza de mejor esfuerzo en una obligatoria.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini",
      "require_redaction": true
    }
  }
}
```

## Acceso al panel

El panel web esta abierto en localhost por defecto, lo que resulta comodo para el desarrollo local. En el momento en que lo expones mas alla de tu maquina, ponlo detras de una contrasena:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Puedes pasar una contrasena literal o una referencia `${ENV_VAR}` para que el secreto quede fuera del archivo. Una vez definida la contrasena, el panel exige iniciar sesion en `/login`. Borrala con `pepe dashboard password --clear`.

La contrasena se lee de `dashboard.password` en la configuracion (interpolada), con respaldo en la variable de entorno `PEPE_DASHBOARD_PASSWORD`. Dos ajustes relacionados endurecen un panel servido detras de un dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define los valores adicionales del encabezado `Host` que el panel acepta. Esto sirve tambien como lista blanca contra el reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista los proxies inversos cuyo encabezado `X-Forwarded-For` puede considerarse confiable. Vacio por defecto, lo que significa que no se confia en ningun encabezado de reenvio.

Vinculado a una interfaz publica sin contrasena, el panel se cierra por defecto y bloquea a los clientes remotos hasta que definas una.

## Tokens de la API

Sin ningun token, la API HTTP responde solo a los llamantes de loopback (localhost), asi que una configuracion local sigue siendo simple mientras que un servidor expuesto en la red nunca es anonimo. Crear el primer token la cierra para todos: a partir de ahi cada peticion a `/v1`, local o remota, necesita un encabezado `Authorization: Bearer` que lleve un token valido. Genera uno con:

```bash
pepe token add --label "ci pipeline"
```

El token en crudo se muestra una sola vez y solo se guarda su hash SHA-256, nunca el token en si. Un token puede acotarse: `--company` lo limita a los agentes de un inquilino, y `--agent` lo limita a un unico agente (que debe vivir dentro de esa empresa). Administralos con `pepe token list` y `pepe token revoke ID`, desde la pagina de tokens de la API del panel, o por chat con un agente que tenga la herramienta protegida `manage_token`. Para las formas de las peticiones y el uso del SDK, consulta la [pagina de la API HTTP](./api/).

## Aislamiento multi-inquilino

El trabajo puede aislarse por empresa (un ambito de inquilino basado en un identificador). El ambito por defecto, sin empresa, se llama Principal. Los agentes, modelos y claves de proveedor de una empresa quedan invisibles para las demas empresas, y un token de API acotado a una empresa alcanza solo a los agentes de esa empresa. Esto evita que las credenciales y conversaciones de un inquilino se filtren jamas a las de otro, lo cual importa cuando alojas agentes en nombre de varios clientes desde una sola instancia de Pepe.
