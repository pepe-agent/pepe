---
title: Panel
description: La interfaz web local para inspeccionar y gestionar agentes, modelos, canales y ejecuciones.
---

El panel es la interfaz web local que levanta `pepe serve`. Desde ahí conversas
con tus agentes, inspeccionas trazas, gestionas conexiones de modelo, configuras
canales, revisas tareas programadas y generas tokens de API, todo sin tocar un
JSON a mano.

```bash
pepe serve          # API, panel y gateways, todo en un mismo proceso
# después abre http://localhost:4000
```

Si trabajas desde el código fuente, compila los assets una vez con `mix
assets.build` antes de correr `mix pepe serve`.

## Sesiones y conversación

Al abrir el panel ves una lista viva de sesiones a la izquierda y, a la derecha,
el panel de conversación con streaming. Elige una sesión para leer su historial
y hablarle a su agente, la respuesta va llegando token por token. `New chat`
arranca una sesión nueva, y cada una muestra en la lista su agente, su modelo y
cuántos turnos lleva; si una sesión está procesando un turno en ese momento
aparece un pequeño indicador en vivo junto a ella, con un botón `Stop` ahí mismo
para interrumpirla sin necesidad de abrirla antes.

Las sesiones viven dentro del proceso que las corre, así que todo tiene que
pasar por el mismo `pepe serve`: solo así el panel llega a ver cada sesión,
incluidas las que entraron por Telegram.

Las herramientas riesgosas también piden autorización aquí mismo: la ejecución
se pausa y aparece un aviso de permitir o denegar, la versión web de los mismos
botones que le llegan a un usuario de Telegram, salvo que el agente ya tenga esa
herramienta preaprobada. El agente propietario, el omnipotente, nunca pregunta.
En [Seguridad y sandbox](../security/) está explicado cómo decide esa barrera.

## Lo que encuentras en la barra lateral

La barra lateral es un espejo de la CLI: casi cualquier cosa que hagas con el
comando `pepe` también la puedes hacer desde aquí.

- **Chat**: conversar con una sesión.
- **Projects**: crear, editar y borrar proyectos, junto con su margen de
  facturación. Ver [Proyectos](../projects/).
- **Agents**: crear, editar y borrar agentes: su persona, modelo, herramientas,
  rutas, ámbito de administración, y cuál queda como predeterminado.
- **Models**: agregar, quitar y editar conexiones de modelo, fijar un precio por
  modelo y elegir el predeterminado.
- **Usage and billing**: uso de tokens y costo por ciclo, por proyecto. Ver [Uso
  y facturación](../billing/).
- **Learning**: la línea de tiempo de TimeLearn. Ver [Aprendizaje](../learning/).
- **Scheduled**: crear, ejecutar y gestionar tareas programadas. Ver [Tareas
  programadas](../scheduled/).
- **Watches**: el "avísame en cuanto pase X" de una sola vez. Ver
  [Watches](../watches/).
- **Channels**: agregar, quitar y editar bots de Telegram, con cambios que se
  aplican en caliente. Ver [Telegram](../telegram/).
- **MCP**: servidores externos de herramientas. Ver [Servidores MCP](../mcp/).
- **Config file**: editar `~/.pepe/config.json` directamente ahí, validado al
  guardar.

## Dejarlo corriendo de forma permanente

`pepe serve` corre en primer plano por defecto: cerrar la terminal o cerrar
sesión lo detiene, y al panel con él. Para un despliegue real conviene
instalarlo como servicio persistente en segundo plano (launchd en macOS,
systemd `--user` en Linux), que aguanta un cierre de sesión o un reinicio y se
reinicia solo si llega a fallar.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Esto solo funciona desde el binario `pepe` instalado, no con `mix pepe serve
install`. Si tus conexiones de modelo usan secretos `${ENV_VAR}`, `install` te
los lista, porque el servicio arranca con un entorno mínimo y esos valores hay
que agregarlos a mano al archivo generado.

## Acceso al panel

Por defecto el panel solo se abre en localhost, lo cual es cómodo mientras
desarrollas. En el momento en que lo expones más allá de tu propia máquina,
ponle una contraseña:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Puedes pasar una contraseña literal o una referencia `${ENV_VAR}` para que el
secreto ni siquiera toque el archivo. Una contraseña literal se guarda ya
hasheada, así que una vez definida nunca vuelve a ser legible, ni desde el
archivo ni desde un backup suyo. Una referencia `${ENV_VAR}` no tiene nada que
hashear, porque el secreto de verdad vive fuera del archivo desde el principio.
Con la contraseña puesta, el panel exige iniciar sesión en `/login`. Para
quitarla, `pepe dashboard password --clear`.

Si corres `pepe dashboard password` sin darle ningún valor, te la pide de forma
interactiva con la entrada oculta mientras escribes, así nunca queda registrada
en el historial de la shell ni visible en un listado de `ps`:

```bash
pepe dashboard password
```

La contraseña se lee de `dashboard.password` en la configuración (ya
interpolada), con la variable de entorno `PEPE_DASHBOARD_PASSWORD` como
respaldo. Hay dos ajustes más para endurecer un panel que corre detrás de un
dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define qué valores
  extra del encabezado `Host` acepta el panel, y de paso funciona como lista
  blanca contra ataques de DNS rebinding.
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` indica qué proxies
  inversos pueden tener su encabezado `X-Forwarded-For` como confiable. Por
  defecto está vacío, es decir que ningún encabezado de reenvío se acepta como
  válido.

Si alguien llega a alcanzar el panel desde fuera de tu máquina sin que hayas
puesto contraseña, el panel bloquea a todo cliente remoto hasta que definas una:
solo la propia máquina puede abrirlo, y una VM, un proxy o incluso la red de tu
oficina cuentan como "fuera" para este propósito. Ante la duda, cierra el paso
en vez de dejarlo abierto.

## Llegar a él desde otro lugar

Para acceder al panel o a la API desde fuera de tu máquina sin abrir un puerto
ni levantar un proxy inverso, `pepe serve` puede abrir un túnel de
[Cloudflare](https://www.cloudflare.com/) (necesitas tener `cloudflared`
instalado):

```bash
pepe serve --tunnel
```

Esto es un **túnel rápido**: imprime una URL al azar,
`https://<algo>.trycloudflare.com`, que solo existe mientras el proceso sigue
corriendo y cambia cada vez que lo reinicias. No necesitas cuenta de
Cloudflare para esto.

Si en cambio quieres una **URL fija, elegida por ti**, en tu propio dominio, usa
un túnel con nombre. Hay dos caminos:

```bash
# Sin navegador (lo mejor para un servidor): crea el túnel y su hostname público
# desde el panel de Cloudflare Zero Trust, apunta su servicio a
# http://localhost:4000, copia el token del conector, y luego:
pepe serve --tunnel --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

# O con un inicio de sesión único desde el navegador (guarda un cert.pem), sin token:
cloudflared tunnel login
pepe serve --tunnel --hostname pepe.example.com
```

Con `--token`, el hostname y a qué servicio apunta viven en el panel de
Cloudflare; ahí `--hostname` es opcional, solo sirve para imprimir la URL al
arrancar. El token es un secreto, así que pásalo siempre como referencia
`${ENV_VAR}`. Toda petición que llega por el túnel se trata como pública, así
que pon una contraseña al panel antes de apoyarte en cualquiera de estas dos
formas.
