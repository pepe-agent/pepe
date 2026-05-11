---
title: Seguridad y entorno aislado
description: Los agentes ejecutan código, así que hacen trabajo real y pueden causar daño real. Pepe apila una barrera de permisos, protecciones de comandos, un entorno aislado opcional, referencias a secretos, hooks de censura y control de acceso, y es honesto sobre lo que hace cada uno.
---

## La amenaza, sin rodeos

Un agente que puede ejecutar un comando o escribir un archivo es útil precisamente porque actúa sobre tu máquina. Ese mismo poder es el riesgo. Pepe no finge que un solo ajuste vuelva esto seguro. En cambio apila varias protecciones independientes, cada una con una tarea clara, y te deja subir la intensidad a medida que crece tu exposición. Esta página recorre cada capa, desde la que siempre está activa hasta la que activas tú mismo para poner un límite firme.

Las capas, de la más débil pero siempre activa a la más fuerte pero opcional:

1. La barrera de permisos. Una persona aprueba cualquier herramienta que actúe.
2. Protecciones de comandos. Un filtro incorporado que rechaza unos pocos comandos catastróficos.
3. El entorno aislado. Un envoltorio opcional que ejecuta comandos de shell en aislamiento real.
4. Secretos. Las credenciales viven como `${ENV_VAR}` o en una bóveda, nunca en el archivo de configuración, y la shell del agente no las hereda.
5. Hooks de censura. Limpieza opcional de datos personales antes de que el texto llegue a un modelo.
6. Control de acceso. La contraseña del panel y los tokens de portador de la API.

<div class="note"><strong>Ningún ajuste por sí solo es un límite de seguridad.</strong> El valor por defecto honesto es la barrera de permisos más las protecciones. Para cualquier cosa que se ejecute sin supervisión o apruebe herramientas de forma automática, añade el entorno aislado, y lo ideal es ejecutar Pepe como un usuario limitado o dentro de un contenedor.</div>

## La barrera de permisos

Cada llamada a una herramienta pasa por una barrera antes de ejecutarse. Las herramientas de solo lectura se ejecutan sin restricciones. Todo lo que actúa (ejecutar un comando, escribir o mover un archivo, cambiar la configuración, y cualquier herramienta de plugin de terceros) debe autorizarse primero.

Las herramientas que nunca preguntan son las de solo lectura: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill` y `send_to_agent`. Cualquier cosa que no esté en esa lista, incluida cualquier herramienta de plugin añadida, se trata como arriesgada y requiere aprobación. Es un valor por defecto deliberadamente seguro: se asume que una herramienta desconocida es peligrosa.

Cuando una herramienta arriesgada no ha sido aprobada de antemano, el runtime pregunta a la persona al otro lado. Cada superficie muestra ese aviso a su manera nativa (botones en línea en un canal de chat, un menú con flechas del teclado en la CLI), pero la decisión siempre es una de cuatro:

- `once`: permite solo esta llamada, pregunta de nuevo la próxima vez.
- `session`: permite durante el resto de esta conversación. Se guarda en memoria y se olvida cuando inicias una nueva sesión o reinicias. Las demás sesiones siguen preguntando.
- `always`: permite de ahora en adelante. Se guarda en el agente en `config.json`.
- `deny`: rechaza. Nunca se recuerda, así que la misma llamada se pregunta otra vez más adelante.

Una llamada denegada no hace fallar la ejecución. Se le informa al modelo que la persona no autorizó la herramienta y se le pide que pruebe otro enfoque o que te consulte, de modo que la conversación continúa.

### Una concesión recuerda para qué se dio

"Permitir siempre bash" era un cheque en blanco. Veías al agente a punto de ejecutar un `ls build/`, lo aprobabas, y ese mismo permiso pasaba a cubrir `rm -rf`, `sudo` y `curl | sh` para siempre. Quien lo firmó estaba mirando un listado de directorio.

Cada llamada se clasifica primero (borra archivos, accede a la red, se ejecuta con privilegios elevados, ejecuta código incrustado), y **la concesión registra los riesgos que estabas mirando de verdad**. Es decir, una lista `auto_approve` real se ve así:

```jsonc
"auto_approve": [
  "bash:none",                  // aprobado para llamadas de bash que no señalan ningún riesgo
  "write_file:writes_file",     // ...y para escribir archivos
  "bash:deletes+network"        // ampliada después, cuando dijiste que sí a un rm y a un curl
]
```

Una llamada se permite cuando todos los riesgos que lleva ya fueron aprobados. Aprobar un `ls` deja pasar `cat` y `grep` sin volver a preguntar, y ese es justamente el objetivo: una barrera que da la lata es una barrera que la gente apaga. Pero el primer `rm` señala `deletes`, no está cubierto, se detiene a preguntar, y la pregunta nombra exactamente aquello a lo que nunca dijiste que sí. Di que sí y la concesión se amplía ahí mismo, así que la lista sigue siendo lo bastante corta para auditarla.

Las formas antiguas, más gruesas, siguen funcionando sin cambios:

| Concesión | Significa |
|---|---|
| `"*"` | toda herramienta, todo riesgo (el agente del propio propietario) |
| `"bash"` | un cheque en blanco sobre bash, tal como lo escribía un Pepe anterior a esto |
| `"bash:any"` | el mismo cheque en blanco, escrito a sabiendas |

<div class="note"><strong>Esto no es un sandbox, y no debe leerse como tal.</strong> La clasificación lee el comando como texto, y el texto miente: un comando puede montarse en tiempo de ejecución, descodificarse desde base64 o esconderse dentro de un script que el propio agente escribió un instante antes. Falla cerrado, en el sentido de que un riesgo no reconocido nunca queda cubierto por una concesión más estrecha. Lo que cierra es la distancia entre lo que una persona miró y lo que de verdad firmó. No convierte en un lugar seguro un contenedor que ejecuta shell elegida por un LLM, y ese contenedor sigue teniendo que ser uno que estarías dispuesto a perder.</div>

### Gestionar las concesiones guardadas

Las concesiones persistentes siguen siendo tuyas, para inspeccionarlas y revocarlas. Desde un canal de chat como Telegram, `/approve` lista lo que el agente puede ejecutar sin preguntar, `/approve clear` borra todas las concesiones guardadas y `/approve clear <tool>` borra solo una. Son comandos de operador, así que únicamente un usuario de confianza puede ejecutarlos.

### Aprobación automática y el agente propietario

Elegir `always` en el aviso registra esa herramienta en la lista `auto_approve` del agente, así que nunca vuelve a preguntar para ese agente. No hay una opción aparte para configurar esto por adelantado desde `pepe agent add`. Otorgas confianza respondiendo `always` una vez cuando aparece el aviso, o editando el agente en `config.json`:

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

Un único comodín `"*"` en `auto_approve` significa que el agente ejecuta cualquier herramienta sin preguntar jamás. Ese es el agente propietario omnipotente que se crea para ti en `pepe setup`: con confianza sobre todas las herramientas para que puedas manejar tu propia máquina sin fricción. Nace también como superadministrador de todos los demás agentes (`can_manage: ["*"]`), así que puede crearlos y reconfigurarlos por chat desde el primer día. Los agentes que añades después tienen un alcance normal. Otorga esa confianza de forma deliberada, y nunca a un agente expuesto a entradas no confiables.

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

<div class="note"><strong>Las superficies sin persona se ejecutan sin restricciones.</strong> La API HTTP no tiene a quien preguntar, así que no aporta ningún aprobador y las herramientas arriesgadas se ejecutan sin preguntar. Trata la API como de plena confianza, y protégela con un token (ver más abajo) antes de exponerla.</div>

### El propietario puede manejar la CLI por chat

La herramienta `manage_pepe` ejecuta los mismos comandos `pepe` no interactivos que escribirías en una terminal (añadir un modelo, definir un agente, generar un token, programar una tarea, administrar empresas), así que un agente propietario de confianza puede operar todo el runtime desde una conversación.

> Tú: Añade un agente llamado researcher con las herramientas web_search y read_file.
>
> Agente: (te pide que confirmes, luego ejecuta `pepe agent add researcher --tools web_search,read_file`) Listo. El agente researcher está preparado.

Es la herramienta más poderosa que existe. Otórgala solo a un agente propietario en el que confíes plenamente, nunca a uno expuesto a entradas no confiables. Como toda herramienta que actúa, pasa por la barrera de permisos, y los comandos interactivos o de larga duración (`setup`, `chat`, `serve` y las pasarelas en primer plano) se rechazan porque no pueden ejecutarse como una sola llamada. Para una tarea única y más acotada, prefiere las herramientas enfocadas: `manage_token` para tokens, `manage_channel` para canales, `schedule_task` para tareas programadas.

## Protecciones de comandos

Las herramientas de shell (`bash` y `run_script`) pasan cada comando por una guardia primero. La guardia rechaza un conjunto pequeño y deliberadamente estrecho de operaciones catastróficas que nunca son legítimas:

- Borrados recursivos de una ruta del sistema, `/`, `~` o `$HOME`.
- Formatear un sistema de archivos (`mkfs`).
- Escribir en crudo o sobrescribir un dispositivo de disco (`dd of=/dev/...`, o redirigir hacia `/dev/sda` y similares).
- Bombas de bifurcación (fork bombs).
- Apagar o reiniciar el equipo (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

Es pura, multiplataforma, sin configuración y siempre activa. No cuesta nada, así que nunca hay que habilitarla.

Ten claro lo que es: una red fina contra accidentes y contra inyección de prompts evidente, no un límite de seguridad. Un comando decidido u ofuscado puede escapar a la inspección estática, y la guardia permite a propósito trabajo potente pero legítimo, como instalar dependencias o consultar una base de datos. Para un límite real, añade el entorno aislado.

## El entorno aislado (aislamiento opcional)

Para un límite de verdad, de modo que ni siquiera un agente con aprobación automática pueda tocar el equipo anfitrión, configura un envoltorio de aislamiento. Un envoltorio es un pequeño ejecutable al que Pepe le pasa cada comando. El envoltorio ejecuta el comando aislado según lo permita el anfitrión, y luego devuelve la salida. Pepe pasa el directorio de trabajo del agente en la variable de entorno `PEPE_SANDBOX_CWD`, para que el envoltorio pueda montar o confinar las escrituras solo a ese directorio.

Cuando no hay envoltorio configurado (el valor por defecto), los comandos se ejecutan directamente en el anfitrión y la barrera de permisos es la protección. Cuando hay un envoltorio configurado, cada comando de shell pasa por él.

La forma más rápida de configurar uno es el flujo de instalación, que escribe un envoltorio listo para usar en `~/.pepe/sandbox/` y apunta la configuración hacia él:

```bash
pepe setup
```

Elige el paso Sandbox y escoge tu aislamiento. Pepe ofrece lo que tu anfitrión admite:

| Anfitrión | Opciones |
|------|------|
| Linux | firejail (ligero, espacios de nombres) o Docker/Podman |
| macOS | sandbox-exec (viene con macOS) o Docker Desktop |
| Windows | Docker o WSL |

Docker es el denominador común portátil: monta solo el espacio de trabajo, así que el resto del sistema de archivos del anfitrión queda invisible, y puedes mantener la red activa cuando el agente necesita una base de datos o una API. El envoltorio de Docker se ajusta con variables de entorno, incluidas `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` o `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS` y `PEPE_SANDBOX_RUNTIME` (`docker` o `podman`).

Si prefieres apuntar a tu propio envoltorio, define la ruta directamente en `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Cualquier ejecutable sirve mientras ejecute sus argumentos (`program arg1 arg2 ...`) de forma aislada y respete `PEPE_SANDBOX_CWD`. La instalación solo advierte, y nunca instala automáticamente, si la herramienta subyacente (docker, firejail, sandbox-exec) falta en tu `PATH`.

<div class="note"><strong>No existe un entorno aislado verdadero, sin configuración y multiplataforma.</strong> Todo aislamiento real necesita una función del sistema operativo o una herramienta externa. Por eso el entorno aislado es opcional y los valores por defecto siempre activos son la barrera más las protecciones. Cuando los agentes se ejecutan sin supervisión o aprueban herramientas de forma automática, trata el entorno aislado como obligatorio, no opcional.</div>

## Los secretos quedan como referencias

La configuración vive en un archivo JSON plano en `~/.pepe/config.json`. No hay base de datos. Para mantener las credenciales fuera de ese archivo, escríbelas como referencias `${ENV_VAR}`. Pepe las interpola contra el entorno al momento de leer y nunca persiste el valor expandido.

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

En tiempo de ejecución la clave real se lee del entorno. En disco el archivo solo contiene el marcador. El mismo mecanismo funciona para los tokens de pasarela, los ajustes de plugins y la contraseña del panel, así que puedes versionar o compartir una configuración sin filtrar nada. Exporta las variables antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Un marcador de cadena completa que se resuelve en nada (la variable no está definida) se trata como "sin definir" en lugar de una cadena vacía, así que un secreto ausente aparece como un claro "no configurado" en vez de un blanco silencioso.

### O guárdalos en una bóveda

Un valor de la configuración puede decir **dónde vive el secreto** en lugar de contenerlo. Pepe lo busca en el momento en que lo necesita:

```json
{ "api_key": "exec:op read op://Trabajo/openai/key" }
{ "api_key": "exec:vault kv get -field=key secret/openai" }
{ "api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text" }
```

Son tres ejemplos, no tres integraciones. **El contrato entero es: un comando que imprime el secreto en la salida estándar.** Pepe no sabe qué es 1Password, y no hay una lista de bóvedas soportadas a la que añadirse. El llavero de macOS, `gcloud secrets`, `pass`, la CLI de Bitwarden y un script que escribiste esta mañana ya funcionan, porque todos imprimen un secreto cuando los ejecutas. `file:/run/secrets/key` cubre un montaje de secreto de Docker o Kubernetes.

Luego **revocas una clave en la bóveda** y deja de funcionar en un minuto, sin ssh, sin editar nada, sin reiniciar. Si tu bóveda necesita una credencial propia (un token de cuenta de servicio, una dirección), nómbrala y solo a ella: `"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }`.

El valor resuelto se cachea en memoria durante 60 segundos, porque abrir una bóveda cuesta unos cientos de milisegundos y un Pepe con tráfico lo pagaría en cada llamada al modelo. Así que el secreto sí vive en el proceso hasta un minuto: esto estrecha la ventana, no la elimina. Una bóveda bloqueada o inalcanzable se lee como un secreto **no configurado**, nunca como uno equivocado.

### Y el agente no ve nada de esto

Uses lo que uses, **la shell del agente no hereda los secretos de Pepe**.

Vale la pena decirlo con todas las letras, porque `${ENV_VAR}` invita a una media verdad cómoda. Mantiene los secretos fuera del **archivo** de configuración, lo cual es real. Y no hacía nada por el **agente**, porque el secreto seguía teniendo que existir en algún sitio para que Pepe lo usara, y ese sitio era el proceso del que la shell del agente es hija. `echo $OPENAI_API_KEY` devolvía la clave. `env` también, que es una sola palabra al alcance de una inyección de prompt.

Un comando que el agente ejecuta recibe ahora el entorno de Pepe menos sus credenciales: cada `${VAR}` a la que apunta la configuración, y cada variable cuyo nombre dice que lo es. `PATH` y `HOME` se quedan, porque un agente que no encuentra `git` es un agente roto, y a un agente roto un humano irritado le arranca las protecciones.

<div class="note"><strong>Esto no es un sandbox.</strong> Un agente que puede ejecutar shell puede leer cualquier archivo que tú puedas leer. Lo que cierra es la fuga más barata y más probable, por mucho, y hace que "la configuración no tiene secretos" deje de ser una frase que significa menos de lo que suena.</div>

### Si un token se pega en el chat

Está comprometido. No por dónde ha acabado, sino por dónde ya ha estado: escrito en un chat significa enviado al proveedor del modelo, escrito en la conversación y escrito en el trace en disco. Pepe **lo guarda y te avisa** en lugar de rechazar la escritura, porque rechazar no deshace la fuga, solo te deja atascado. Revócalo, reemítelo, y pon el nuevo en una variable de entorno o en una bóveda. `pepe doctor` sigue diciéndolo hasta que lo hagas.

### Hazlo por chat

Un agente al que se le otorgan las herramientas de solo lectura `config_get` y `doctor` puede informar sobre tu configuración y detectar un secreto ausente en una conversación normal. Ambas son de solo lectura, así que nunca activan la barrera de permisos.

> Tú: ¿Está todo configurado correctamente?
>
> Agente: (ejecuta `doctor`) Encontré un problema: la conexión de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, pero esa variable no está definida en el entorno. Expórtala antes de servir.

La herramienta `doctor` hace un comprobación de salud de toda la configuración y marca secretos `${ENV}` sin definir, agentes que apuntan a modelos ausentes, programaciones inválidas y conexiones inalcanzables. Pasa `live: true` para también sondear la red.

<div class="note"><strong>Los ajustes sensibles a la seguridad no se pueden editar por chat.</strong> La herramienta protegida `config_set` está cerrada por defecto: solo toca una lista blanca corta (el modelo y el agente por defecto, el idioma, la zona horaria y un par de opciones de Telegram). Los secretos, las listas de herramientas permitidas, los tokens de bot, el envoltorio del entorno aislado y la contraseña del panel quedan a propósito fuera de esa lista, así que `config_set` no puede cambiarlos. Esos los defines tú con la CLI o el panel. Los tokens de la API son lo único que un agente puede generar por chat, pero solo a través de la herramienta separada y protegida por la barrera de permisos `manage_token`, nunca mediante `config_set`.</div>

## Hooks de censura (limpieza opcional de datos personales)

Si tus agentes manejan datos personales, puedes limpiarlos antes de que lleguen a un modelo. Los hooks de censura se ejecutan sobre el flujo de mensajes y se habilitan por agente, así que solo los agentes que los necesitan pagan el coste.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Tres puntos del flujo se censuran: el mensaje de entrada del humano, **el resultado bruto de cualquier herramienta** (una consulta a la base de datos, la lectura de un archivo, una búsqueda web, cualquier cosa que una herramienta traiga, no solo lo que escribió un humano), y la respuesta de salida del agente. El resultado de la herramienta se censura antes de unirse a la conversación y antes de escribirse en disco, así que un resultado grande que termine volcado en un archivo del workspace (ver Agentes) sale ya censurado, nunca en bruto. Pide "lista los 10 pacientes más recientes con diagnóstico cardíaco" contra tu propia base de datos y, con `pii_redact` activado, el modelo razona sobre `[PERSON_1]`, `[PERSON_2]`, ...; solo la respuesta final para ti recibe los nombres reales de vuelta.

Vienen cuatro hooks de fábrica:

- `pii_redact`: un censor de expresiones regulares, sin conexión y sin dependencias. Reemplaza datos personales estructurados (correo, número de tarjeta e identificaciones nacionales como el CPF o el CNPJ) con un token estable como `[CPF_1]`. Por defecto es reversible: registra `token -> real` para que la tubería pueda restaurar el valor real en la respuesta de salida.
- `llm_redact`: usa un modelo local o configurado para reemplazar nombres, direcciones y texto libre con seudónimos realistas, y luego los restaura a la salida. Va mejor junto a `pii_redact`, que maneja las identificaciones estructuradas de forma determinista mientras el modelo se ocupa de las partes desordenadas en cualquier idioma.
- `presidio`: envía el texto a través de tus propios contenedores autoalojados de análisis y anonimización de Microsoft Presidio, así los datos quedan bajo tu control.
- `http_redact`: la válvula de escape genérica. Pepe publica el mensaje en tu propio endpoint, que devuelve el texto transformado, así cualquier servicio de censura se conecta sin un adaptador dedicado.

Los ajustes globales de cada hook (qué paquetes de reconocedores, patrones personalizados, si mantenerlo reversible) viven bajo `"hooks"` en `config.json`. Puedes pedirle a un modelo que redacte una configuración de `pii_redact` por ti:

```bash
pepe hooks list
pepe hooks generate "redact Brazilian CPF, emails, and phone numbers" --save
```

Los hooks de expresiones regulares y de HTTP fallan de forma abierta por diseño: si un censor da error o un modelo no está disponible, el texto original pasa en lugar de bloquear el trabajo. Cuando necesitas una garantía firme, marca la conexión de modelo con `require_redaction` en `config.json`. Un modelo marcado así se niega a ejecutarse a menos que el agente tenga al menos un hook de censura habilitado, convirtiendo una limpieza de mejor esfuerzo en una obligatoria.

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

El panel web está abierto en localhost por defecto, lo que resulta cómodo para el desarrollo local. En el momento en que lo expones más allá de tu máquina, ponlo detrás de una contraseña:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Vinculado a una interfaz pública sin contraseña, el panel se cierra por defecto y bloquea a los clientes remotos hasta que definas una. Los detalles completos están en la página [Panel](../dashboard/): la lista blanca de `Host` y los ajustes de trusted-proxies para servirlo detrás de un dominio, y cómo ejecutarlo como servicio persistente.

## Tokens de la API

Sin ningún token, la API HTTP responde solo a los llamantes de loopback (localhost), así que una configuración local sigue siendo simple mientras que un servidor expuesto en la red nunca es anónimo. Crear el primer token la cierra para todos: a partir de ahí cada petición a `/v1`, local o remota, necesita un encabezado `Authorization: Bearer` que lleve un token válido. Genera uno con:

```bash
pepe token add --label "ci pipeline"
```

El token en crudo se muestra una sola vez y solo se guarda su hash SHA-256, nunca el token en sí. Un token puede acotarse: `--company` lo limita a los agentes de una empresa, y `--agent` lo limita a un único agente (que debe vivir dentro de esa empresa). Adminístralos con `pepe token list` y `pepe token revoke ID`, desde la página de tokens de la API del panel, o por chat con un agente que tenga la herramienta protegida `manage_token`. Para las formas de las peticiones y el uso del SDK, consulta la [página de la API HTTP](../api/).

## Aislamiento multiempresa

El trabajo puede aislarse por empresa (un ámbito de empresa basado en un identificador). El ámbito por defecto, sin empresa, se llama Principal. Los agentes, modelos y claves de proveedor de una empresa quedan invisibles para las demás empresas, y un token de API acotado a una empresa alcanza solo a los agentes de esa empresa. Esto evita que las credenciales y conversaciones de una empresa se filtren jamás a las de otra, lo cual importa cuando alojas agentes en nombre de varios clientes desde una sola instancia de Pepe.
