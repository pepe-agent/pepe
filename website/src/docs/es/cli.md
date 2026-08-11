---
title: Referencia de la CLI
description: Todos los comandos de pepe, agrupados por lo que gestionan, conexiones de modelo, agentes, proyectos, tokens, el panel, y más.
---

Todo en Pepe es accesible desde la línea de comandos, agrupado aquí como realmente lo
buscarías: por lo que estás intentando hacer, no por orden alfabético. Cada ejemplo usa
el binario `pepe` instalado; desde un checkout del código fuente usa `mix pepe` en su
lugar, ambos aceptan los mismos subcomandos.

```bash
pepe help              # la lista completa de comandos
pepe help <grupo>       # ej.: pepe help agent
```

## Configuración inicial

```bash
pepe setup   # primera vez: asistente guiado (idioma -> modelo -> agente -> Telegram)
              # siguientes veces: un menú para añadir o reconfigurar cualquier parte
```

## Conexiones de modelo

```bash
pepe model                       # muestra la predeterminada, cambia entre las guardadas, o añade una nueva
pepe model add openai            # guiado: elige proveedor -> método de inicio de sesión -> modelo
pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # totalmente manual
pepe model providers             # lista proveedores conocidos (OpenAI, Anthropic, Gemini, ...)
pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
pepe model list                  # lista las conexiones guardadas
pepe model test [NOMBRE]         # prueba una conexión para confirmar que funciona
pepe model reconnect openai      # inicia sesión de nuevo para arreglar una conexión rota, sin tocar el resto
pepe model remove openrouter
pepe model default openai
```

¿Ya pagas ChatGPT/Codex o Claude Pro/Max? Puedes añadirlo **iniciando sesión con esa
cuenta** en vez de pegar una clave de API: `pepe model add openai` -> "ChatGPT / Codex
subscription" abre tu navegador, inicias sesión, y Pepe se encarga del resto. Mira
[Modelos](../models/).

Si esa conexión deja de funcionar (la sesión caducó, o cerraste sesión en otro sitio),
`pepe model reconnect NOMBRE` inicia sesión de nuevo y lo arregla en el sitio. Nada más
de la conexión cambia, así que cualquier agente que ya la usara sigue funcionando sin
que tengas que tocar nada. No la elimines y la vuelvas a añadir para arreglar esto: eso
empieza todo de cero y pierde cualquier precio o ajuste que tuvieras configurado.

## Agentes

```bash
pepe agent add assistant \
  --prompt "Eres un agente de programación útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # deja que assistant envíe mensajes a helper (ver Rutas)
pepe agent manage boss assistant     # deja que boss administre a assistant ("*" = todos)
pepe agent rename assistant helper   # renombra + mueve su carpeta de trabajo
pepe agent remove helper
pepe agent default assistant
```

Mira [Agentes](../agents/) para saber qué hace cada opción.

## Proyectos (más de un cliente o equipo en el mismo Pepe)

Si usas Pepe para varios clientes o equipos desde una sola instalación, cada uno es un
**proyecto**, con sus propios agentes y datos, separado de los demás. Sin `--project`,
todo usa el proyecto predeterminado, tal como una instalación de un solo cliente siempre
ha funcionado. Mira [Proyectos](../projects/).

```bash
pepe project add acme --description "Acme Inc"     # crea un nuevo cliente/proyecto
pepe project list
pepe project rename acme umbrella                  # lo renombra; nada más se rompe
pepe agent add sales --project acme --prompt "..."  # agente "acme/sales"
pepe agent list --project acme                     # solo los agentes de Acme
pepe agent list --all                              # todos los proyectos
pepe run acme/sales "hola"                         # lo ejecuta por su handle
pepe project remove acme --force                   # elimina el proyecto + sus agentes
```

## Ejecutar

```bash
pepe run "lista los archivos aquí y resume el proyecto"   # one-shot, transmite al stdout
pepe run assistant "hola"                                  # elige un agente explícitamente
pepe chat                            # conversación interactiva, recuerda lo dicho
pepe chat --agent assistant          # ...con un agente específico (o: pepe chat assistant)
pepe goal "publica las notas de la versión" \
  --criteria "el CHANGELOG tiene una sección fechada" --max-attempts 5   # sigue hasta que esté realmente listo
pepe serve --port 4000               # levanta la API, el panel y el WebSocket juntos
pepe serve --port 4000 --bind lan     # ...accesible desde otras máquinas, no solo esta
pepe serve install [--port 4000]     # lo mantiene corriendo en segundo plano para siempre
pepe serve status                    # ¿está instalado y corriendo?
pepe serve uninstall                 # lo detiene y elimina
```

`goal` no se detiene en el primer intento: un revisor independiente comprueba el
resultado contra `--criteria` y Pepe vuelve a intentarlo (hasta `--max-attempts` veces)
hasta que de verdad quede bien. Usa `--judge MODELO` para que revise un modelo distinto.
Mira [Objetivos](../goals/).

`serve install` hace que Pepe arranque solo y siga corriendo en segundo plano, aunque
cierres sesión, reinicies, o incluso si falla. Solo funciona desde la app `pepe`
instalada, no desde un checkout del código fuente. `--bind` también aplica ahí
(`serve install --bind lan`).

`serve` se vincula solo a `127.0.0.1` por defecto - solo esta máquina puede
alcanzarlo, ya que un `serve` sin más no tiene proxy inverso delante y la API `/v1`
queda abierta sin autenticación hasta que configures un token. `--bind lan` lo abre
a todas las interfaces de red; define antes una contraseña del panel
(`pepe dashboard password`), o usa `--tunnel` para exponerlo públicamente sin
ampliar el vínculo. Este valor por defecto no aplica a la imagen Docker oficial,
que siempre se vincula a todas las interfaces - mira
[Desplegar en un servidor](../deploy/) para el motivo.

`chat` (también llamado `tui`) abre una conversación directamente en tu terminal que
recuerda el contexto mientras la usas. Escribe `/help` dentro para ver todos los
atajos (nueva conversación, deshacer, cambiar de agente o modelo, y más).

## Gateway de Telegram

```bash
pepe gateway telegram setup      # interactivo: token del bot, quién puede hablarle, qué agente
pepe gateway telegram            # lo ejecuta en primer plano
```

Mira [Telegram](../telegram/) para entender el acceso y varios bots.

## Tokens de acceso a la API

Claves que otras apps usan para hablar con Pepe por HTTP o WebSocket. Sin ninguna
creada, solo se aceptan peticiones desde la propia máquina; en cuanto creas una, toda
petición necesita un token válido. Un token puede limitarse a un proyecto (`--project`)
o a un agente (`--agent HANDLE`). Mira [API HTTP](../api/).

```bash
pepe token add --project acme --label "app móvil de acme"   # muestra la clave solo una vez, guárdala ya
pepe token add --agent acme/sales --label "una integración"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # seguro para poner en el código público de una página
pepe token list                        # id, ámbito, permisos, etiqueta
pepe token update <id> --greeting "¡Hola! ¿Cómo puedo ayudarte?"
pepe token revoke <id>
```

El ámbito decide *de quién* son los datos que un token alcanza; los permisos deciden
*qué* puede hacer con ellos. Es decir, puedes darle a alguien un token que solo lea
informes de facturación, sin que pueda conversar con un agente. Mira [Uso y
facturación](../billing/).

```bash
# un token solo de facturación: lee /v1/usage, no puede ejecutar un agente, y ve solo lo
# que el cliente realmente paga (--prices list oculta tu margen; --prices all también lo muestra)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # lo cambia en el sitio, la clave sigue igual
pepe token permissions <id> --no-usage
```

## Watches ("avísame en cuanto pase X")

Comprueba algo periódicamente y avisa **una vez**, en cuanto sea cierto, y después se
detiene solo. Mira [Watches](../watches/).

```bash
pepe watch add "sitio activo" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Tareas programadas

Tareas de agente que se repiten con un horario, como un cron. Mira [Tareas
programadas](../scheduled/).

```bash
pepe cron list
pepe cron add --name "resumen diario" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # la dispara ahora, fuera de su horario
pepe cron logs <id>
```

## Flows (repetir algo que ya funcionó, sin volver a pensarlo)

Cuando un agente resuelve algo de la misma forma un par de veces, convierte esa
secuencia en un `flow` con nombre que se repite directamente la próxima vez, más
rápido y sin pedirle al modelo que lo piense todo de nuevo desde cero. Mira
[Flows](../flows/).

```bash
pepe flow list AGENTE
pepe flow promote NOMBRE --agent AGENTE --from ID1,ID2[,...] [--overwrite]
pepe flow show AGENTE NOMBRE
pepe flow remove AGENTE NOMBRE
pepe flow run AGENTE NOMBRE                                    # lo ejecuta ahora
pepe flow schedule AGENTE NOMBRE --schedule "..." [--timezone TZ] [--deliver ...]
```

## Aprendizaje

```bash
pepe timelearn [AGENTE]                 # lo que el agente ha aprendido, con el tiempo
pepe learn consolidate [AGENTE]         # lo ordena ahora
pepe learn auto [AGENTE] [--at CRON]    # lo hace automáticamente cada noche (--off para apagarlo)
pepe learn status                       # qué agentes están configurados para esto
```

Mira [Aprendizaje](../learning/) para saber qué se guarda realmente.

## Uso, facturación y traces

```bash
pepe usage                                  # tokens y costo por ciclo, por proyecto
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # una línea por conversación
pepe usage runs <id>                        # esa conversación, paso a paso
pepe usage export --project acme            # una factura de cliente (Markdown, o --format csv)
pepe usage prices [--refresh]               # ve o actualiza los precios actuales de modelo
pepe traces [--project NOMBRE] [--limit N]  # actividad reciente, cualquier canal
pepe traces <id>                            # reproduce una ejecución paso a paso
```

Los mismos números están disponibles por HTTP con un token con ámbito de uso. Mira
[Uso y facturación](../billing/).

## Servidores de herramientas, plugins y hooks de privacidad

```bash
pepe mcp add NOMBRE --command npx --args "..."       # un servidor de herramientas local
pepe mcp add NOMBRE --url URL --header "K: V"        # un servidor de herramientas remoto (HTTP)
pepe mcp list | tools NOMBRE | remove NOMBRE         # inspecciona y gestiona
pepe mcp login|logout NOMBRE                         # inicia sesión en un servidor remoto
pepe plugin list | install | scan | remove           # herramientas y canales extra
pepe plugin route list | enable NOMBRE | disable NOMBRE  # endpoint web propio de un plugin
pepe skill list | search | install | update | remove | audit | tap  # marketplace de skills
pepe db add | list | remove              # deja que un agente consulte una base de datos externa
pepe slot list | set | clear             # qué plugin se encarga de una capacidad concreta
pepe policy list                         # reglas de permisos instaladas y dónde aplican
pepe policy scope NOMBRE --agents a,b [--projects x,y] | --clear   # limita dónde aplica una regla
pepe hooks list                          # hooks de privacidad disponibles
pepe hooks generate "oculta DNIs" [--model NOMBRE] [--save]   # deja que la IA escriba uno por ti
```

Mira [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Base de
datos](../database/) y [Privacidad y hooks](../privacy/).

## Calidad y operaciones

```bash
pepe eval [SUITE]                # ejecuta un conjunto de preguntas de prueba en un agente
pepe doctor [--offline]          # comprueba que todo está bien configurado
pepe review [approve|reject ID]  # aprueba o rechaza cambios que un agente hizo por su cuenta
pepe backup [--output ARCHIVO.tgz]  # guarda todo (configuración, agentes, conversaciones, base de datos)
pepe backup verify ARCHIVO.tgz      # confirma que un backup está íntegro
pepe restore ARCHIVO.tgz [--force]  # trae de vuelta un backup
pepe migrate ORIGEN [--dry-run]  # trae modelos/agentes desde otra herramienta
pepe update                      # actualiza a la última versión
pepe browser install             # prepara el navegador que un agente puede usar
```

Mira [Evaluaciones](../evals/), [Backup](../backup/) y [Navegador](../browser/).

## Panel

Una contraseña es opcional. Sin ella, el panel solo se abre en la misma máquina donde
corre; quien intente conectarse desde otro sitio queda bloqueado. Mira
[Autenticación](../auth/) y [Panel](../dashboard/).

```bash
pepe dashboard                            # ve la configuración actual
pepe dashboard password                   # define una, la escribes oculta, no aparece nada en pantalla
pepe dashboard hosts app.example.com      # permite acceder por un dominio (--clear la reinicia)
pepe dashboard trusted-proxies 10.0.0.0/8 # necesario si está detrás de un proxy inverso
```

## Varios

```bash
pepe tools     # lista todas las herramientas que un agente puede usar
pepe config    # dónde está el archivo de configuración, y un resumen rápido
pepe help      # ayuda completa de comandos (o: pepe help <grupo>)
```
