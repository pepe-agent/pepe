---
title: Referencia de la CLI
description: Todos los comandos de pepe, agrupados según lo que gestionan. conexiones de modelo, agentes, proyectos, tokens, el panel, y más.
---

En Pepe todo se puede hacer desde la línea de comandos, y aquí los agrupamos como
realmente los vas a necesitar: por lo que quieres lograr, no por orden alfabético. Cada
ejemplo usa el binario `pepe` ya instalado; si trabajas desde un checkout del código
fuente, usa `mix pepe` en su lugar, los subcomandos son idénticos en ambos casos.

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
pepe model add openai            # guiado: elige proveedor -> método de autenticación -> modelo
pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # totalmente manual
pepe model providers             # lista los proveedores conocidos (OpenAI, Anthropic, Gemini, ...)
pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
pepe model list                  # lista las conexiones guardadas
pepe model test [NOMBRE]         # verifica que una conexión funciona, clave y endpoint incluidos
pepe model reconnect openai      # vuelve a iniciar sesión para reparar una conexión rota, sin tocar nada más
pepe model remove openrouter
pepe model default openai
```

¿Ya pagas una suscripción de ChatGPT/Codex o de Claude Pro/Max? En vez de pegar una
clave de API, puedes añadirla **iniciando sesión con esa misma cuenta**: al correr
`pepe model add openai` elige "ChatGPT / Codex subscription", se abre tu navegador,
inicias sesión ahí, y Pepe se encarga del resto. Los detalles están en
[Modelos](../models/).

Cuando esa conexión deja de funcionar (la sesión caducó, o cerraste sesión en otro
lado), `pepe model reconnect NOMBRE` la repara en el sitio volviendo a autenticarte.
No cambia nada más de la conexión, así que todos los agentes que ya la usaban siguen
funcionando sin configuración extra. Eliminarla y volverla a crear no es la forma de
arreglar esto: eso empieza de cero y te hace perder cualquier precio o ajuste
personalizado que tuvieras puesto.

## Agentes

```bash
pepe agent add assistant \
  --prompt "Eres un agente de programación útil." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # permite que assistant le mande mensajes a helper (ver Rutas)
pepe agent manage boss assistant     # permite que boss administre a assistant ("*" = todos)
pepe agent rename assistant helper   # lo renombra y mueve su carpeta de trabajo
pepe agent remove helper
pepe agent default assistant
```

Qué hace cada opción está explicado en [Agentes](../agents/).

## Proyectos (cuando llevas más de un cliente o equipo)

Si usas una sola instalación de Pepe para varios clientes o equipos, cada uno vive
como un **proyecto** aparte, con sus propios agentes y sus propios datos, sin mezclarse
con los demás. Si nunca pasas `--project`, todo cae en el proyecto predeterminado,
exactamente como funciona hoy cualquier instalación de un solo cliente. Más detalles
en [Proyectos](../projects/).

```bash
pepe project add acme --description "Acme Inc"     # crea un cliente/proyecto nuevo
pepe project list
pepe project rename acme umbrella                  # lo renombra sin romper nada más
pepe agent add sales --project acme --prompt "..."  # agente "acme/sales"
pepe agent list --project acme                     # solo los agentes de Acme
pepe agent list --all                              # todos los proyectos juntos
pepe run acme/sales "hola"                         # lo ejecuta usando su handle
pepe project remove acme --force                   # borra el proyecto entero, agentes incluidos
```

## Ejecutar

```bash
pepe run "lista los archivos aquí y resume el proyecto"   # ejecución única, transmite al stdout
pepe run assistant "hola"                                  # elige un agente en concreto
pepe chat                            # conversación interactiva que recuerda lo dicho
pepe chat --agent assistant          # ...con un agente concreto (o: pepe chat assistant)
pepe goal "publica las notas de la versión" \
  --criteria "el CHANGELOG tiene una sección con fecha" --max-attempts 5   # insiste hasta que quede bien de verdad
pepe serve --port 4000               # levanta la API, el panel y el WebSocket a la vez
pepe serve --port 4000 --bind lan     # ...accesible desde otras máquinas, no solo esta
pepe serve install [--port 4000]     # lo deja corriendo en segundo plano de forma permanente
pepe serve status                    # ¿está instalado y corriendo?
pepe serve uninstall                 # lo detiene y lo quita
```

`goal` no da por terminado el primer intento: un revisor independiente evalúa el
resultado contra lo que pediste en `--criteria`, y si no pasa, Pepe reintenta hasta
`--max-attempts` veces. Para que el revisor sea un modelo distinto usa `--judge
MODELO`. Se explica en detalle en [Objetivos](../goals/).

`serve install` hace que Pepe arranque solo y siga corriendo en segundo plano pase lo
que pase: que cierres sesión, que reinicies la máquina, incluso que se caiga. Esto
solo funciona con la app `pepe` ya instalada, no sirve desde un checkout del código
fuente. El flag `--bind` también se puede pasar aquí (`serve install --bind lan`).

Por defecto `serve` solo escucha en `127.0.0.1`, es decir, solo se puede alcanzar
desde la misma máquina: un `serve` sin más opciones no trae proxy inverso delante, y
la API `/v1` queda abierta sin autenticación hasta que configures un token. `--bind
lan` lo abre a todas las interfaces de red; antes de eso conviene poner una
contraseña al panel (`pepe dashboard password`), o usar `--tunnel` para exponerlo al
público sin ampliar el bind. Esta precaución por defecto no se aplica a la imagen
Docker oficial, que siempre escucha en todas las interfaces; el motivo está explicado
en [Desplegar en un servidor](../deploy/).

`chat` (también llamado `tui`) abre una conversación directamente en tu terminal, que
va recordando el contexto a medida que avanzas. Escribe `/help` ahí dentro para ver
todos los atajos disponibles: nueva conversación, deshacer, cambiar de agente o de
modelo, y más.

## Gateway de Telegram

```bash
pepe gateway telegram setup      # interactivo: token del bot, quién puede hablarle, qué agente lo atiende
pepe gateway telegram            # lo corre en primer plano
```

Cómo funcionan el acceso y varios bots a la vez se explica en [Telegram](../telegram/).

## Tokens de acceso a la API

Son las claves que otras apps usan para hablar con Pepe por HTTP o WebSocket. Mientras
no crees ninguno, solo se aceptan peticiones desde la propia máquina; en cuanto creas
el primero, toda petición pasa a necesitar un token válido. Un token puede acotarse a
un proyecto (`--project`) o a un agente puntual (`--agent HANDLE`). Ver [API
HTTP](../api/).

```bash
pepe token add --project acme --label "app móvil de acme"   # la clave se muestra una sola vez, guárdala ya
pepe token add --agent acme/sales --label "una integración"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # seguro para dejarlo en el código fuente público de una página
pepe token list                        # id, ámbito, permisos, etiqueta
pepe token update <id> --greeting "¡Hola! ¿Cómo puedo ayudarte?"
pepe token revoke <id>
```

El ámbito decide *de quién* son los datos a los que llega un token; los permisos
deciden *qué* puede hacer con ellos una vez ahí. Por eso puedes entregarle a alguien
un token que solo lea reportes de facturación, sin que pueda ni siquiera hablar con un
agente. Ver [Uso y facturación](../billing/).

```bash
# un token solo de facturación: lee /v1/usage, no puede ejecutar ningún agente, y ve
# nada más que lo que el cliente realmente paga (--prices list oculta tu margen, --prices all lo muestra)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # lo cambia en el sitio, la clave en sí no cambia
pepe token permissions <id> --no-usage
```

## Watches ("avísame en cuanto pase X")

Vigila algo con cierta frecuencia y te avisa **una sola vez**, justo cuando se cumple,
y a partir de ahí se detiene solo. Ver [Watches](../watches/).

```bash
pepe watch add "sitio activo" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Tareas programadas

Son trabajos de agente que se repiten según un horario, al estilo de un cron. Ver
[Tareas programadas](../scheduled/).

```bash
pepe cron list
pepe cron add --name "resumen diario" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # la dispara ahora mismo, fuera de su horario habitual
pepe cron logs <id>
```

## Flows (repetir algo que ya salió bien, sin repensarlo)

Cuando un agente ya resolvió lo mismo un par de veces siguiendo los mismos pasos,
conviene convertir esa secuencia en un `flow` con nombre propio: la próxima vez se
repite directamente, más rápido y sin pedirle al modelo que lo razone otra vez desde
cero. Ver [Flows](../flows/).

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
pepe timelearn [AGENTE]                 # todo lo que el agente fue aprendiendo con el tiempo
pepe learn consolidate [AGENTE]         # lo ordena ahora mismo
pepe learn auto [AGENTE] [--at CRON]    # lo hace solo, cada noche (--off para apagarlo)
pepe learn status                       # qué agentes tienen esto activado
```

Qué se guarda realmente está explicado en [Aprendizaje](../learning/).

## Uso, facturación y traces

```bash
pepe usage                                  # tokens y costo por ciclo, desglosado por proyecto
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # una línea por conversación
pepe usage runs <id>                        # esa conversación en detalle, paso a paso
pepe usage export --project acme            # una factura para el cliente (Markdown, o --format csv)
pepe usage prices [--refresh]               # consulta o actualiza los precios vigentes de cada modelo
pepe traces [--project NOMBRE] [--limit N]  # actividad reciente, en cualquier canal
pepe traces <id>                            # reproduce una ejecución paso a paso
```

Los mismos números están disponibles por HTTP usando un token con ámbito de uso. Ver
[Uso y facturación](../billing/).

## Servidores de herramientas, plugins y hooks de privacidad

```bash
pepe mcp add NOMBRE --command npx --args "..."       # un servidor de herramientas local
pepe mcp add NOMBRE --url URL --header "K: V"        # un servidor de herramientas remoto (HTTP)
pepe mcp list | tools NOMBRE | remove NOMBRE         # inspecciona y gestiona
pepe mcp login|logout NOMBRE                         # inicia sesión en un servidor remoto
pepe plugin list | install | scan | remove           # herramientas y canales adicionales
pepe plugin route list | enable NOMBRE | disable NOMBRE  # el endpoint web propio de un plugin
pepe skill list | search | install | update | remove | audit | tap  # marketplace de skills
pepe db add | list | remove              # permite que un agente consulte una base de datos externa
pepe slot list | set | clear             # qué plugin atiende cada capacidad
pepe policy list                         # reglas de permisos instaladas y dónde se aplican
pepe policy scope NOMBRE --agents a,b [--projects x,y] | --clear   # limita dónde se aplica una regla
pepe hooks list                          # hooks de privacidad disponibles
pepe hooks generate "oculta los DNI" [--model NOMBRE] [--save]   # deja que la IA te escriba uno
```

Ver [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Base de
datos](../database/) y [Privacidad y hooks](../privacy/).

## Calidad y operaciones

```bash
pepe eval [SUITE]                # corre un conjunto de prompts de prueba contra un agente
pepe doctor [--offline]          # comprueba que todo esté bien configurado
pepe review [approve|reject ID]  # aprueba o rechaza cambios que un agente hizo por su cuenta
pepe backup [--output ARCHIVO.tgz]  # guarda todo: configuración, agentes, conversaciones, base de datos
pepe backup verify ARCHIVO.tgz      # confirma que un backup está íntegro
pepe restore ARCHIVO.tgz [--force]  # restaura un backup
pepe migrate ORIGEN [--dry-run]  # trae modelos y agentes desde otra herramienta
pepe update                      # actualiza a la última versión
pepe browser install             # prepara el navegador que puede usar un agente
```

Ver [Evaluaciones](../evals/), [Backup](../backup/) y [Navegador](../browser/).

## Panel

La contraseña es opcional. Si no la defines, el panel solo se abre desde la misma
máquina donde corre; cualquier intento de conexión desde otro sitio queda bloqueado.
Ver [Autenticación](../auth/) y [Panel](../dashboard/).

```bash
pepe dashboard                            # muestra la configuración actual
pepe dashboard password                   # define una, se escribe oculta y no aparece en pantalla
pepe dashboard hosts app.example.com      # permite acceder por un dominio (--clear para reiniciarlo)
pepe dashboard trusted-proxies 10.0.0.0/8 # necesario cuando corre detrás de un proxy inverso
```

## Otros

```bash
pepe tools     # lista todas las herramientas que puede usar un agente
pepe config    # dónde vive el archivo de configuración, y un resumen rápido
pepe help      # ayuda completa de comandos (o: pepe help <grupo>)
```
