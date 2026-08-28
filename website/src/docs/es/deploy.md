---
title: Desplegar en un servidor
description: Pon Pepe en un servidor con dominio y TLS, usando Docker Compose, Docker Swarm o Kamal.
---

[Docker](/es/docs/docker/) se encarga del contenedor. Aquí cubrimos el paso siguiente:
subirlo a una máquina a la que otras personas puedan llegar, detrás de un dominio propio
y con certificado.

Da igual la herramienta que elijas: el contenedor es siempre el mismo, y los dos
volúmenes también. Lo que cambia es todo el entorno alrededor, y ese cambio no salta a
la vista, porque en tu máquina local esas piezas son valores por defecto en los que
jamás tuviste que pensar.

## Cuatro cosas que cambian en cuanto sale de localhost

**La contraseña del panel pasa a ser obligatoria.** Ya era así en Docker, y por el mismo
motivo: para Pepe, lo único que cuenta como privado (loopback) es lo que llega desde la
propia máquina; todo lo demás es red pública, y sin contraseña cada petición de ese tipo
recibe un 403. Detrás de un proxy inverso, eso es *todas* las peticiones.

**`PHX_HOST` es el nombre público.** Es lo que Pepe usa para construir URLs absolutas:
los embeds del widget y las URLs de webhook que entregas a Telegram o WhatsApp. Si lo
dejas sin definir, cae en `localhost`, y esas URLs quedan mal sin que nada lo avise,
mientras el resto sigue funcionando.

**`SECRET_KEY_BASE`, o todos pierden la sesión en cada deploy.** Sin definirlo, Pepe
genera uno al azar en cada arranque: para un contenedor suelto no pasa nada, pero en un
servidor es un problema, porque las cookies de sesión firmadas con el secreto anterior
dejan de ser válidas. Genera uno una sola vez (`openssl rand -base64 48`) y consérvalo.

**Dos ajustes solo existen en `config.json`.** No tienen variable de entorno, así que se
configuran después del primer arranque, no al levantar el contenedor. El propio CLI
`pepe` dentro del contenedor solo despacha comandos en el binario Burrito, no en esta
release simple, así que el camino es `bin/pepe rpc`, llamando a `dispatch_attached/1`
(seguro incluso contra un nodo que ya está sirviendo tráfico, ver
[Docker](/es/docs/docker/#acceso-al-nodo)):

```bash
docker exec -it <contenedor> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "hosts", "agents.example.com"])'
docker exec -it <contenedor> bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["dashboard", "trusted-proxies", "10.0.1.0/24"])'
```

`allowed_hosts` cierra la puerta al DNS rebinding: con contraseña puesta pero sin lista
de dominios permitidos, Pepe acepta cualquier `Host`, porque la contraseña es el único
cerrojo y no tiene forma de saber qué dominio querías decir. `trusted_proxies` es el
ajuste que la gente se salta y después diagnostica mal: si lo dejas vacío, cada
`X-Forwarded-For` se ignora, el limitador de intentos de acceso ve la dirección del
proxy para todo el mundo por igual, y todo internet termina compartiendo un único cupo.
Usa la red donde tu proxy realmente vive, nunca `0.0.0.0/0`: confiar en cualquier
cabecera de reenvío equivale a no tener limitador.

<div class="note"><strong>Una réplica. Siempre.</strong> De los dos almacenes que Pepe guarda en ese volumen, el peligro real no es tanto el estado que contienen. Es que una segunda instancia levanta su propio scheduler, y entonces cada cron, watch y compromiso dispara dos veces (la <a href="#el-único-valor-por-defecto-que-hay-que-cambiar">sección de Kamal</a> entra en detalle, y aplica a todas las herramientas de esta página). Dos contenedores con dos volúmenes distintos son un problema todavía más silencioso: son dos Pepes separados, cada uno convencido de ser el único. Por eso cada ejemplo de abajo fija una sola réplica, y donde el orquestador arranca por defecto el contenedor nuevo antes de apagar el viejo, aquí se desactiva esa opción.</div>

## Docker Compose, detrás de Caddy

Es lo mínimo que hace falta para funcionar en una sola máquina. Caddy pide su propio
certificado sin que tengas que configurar nada más que el nombre de dominio.

```yaml
# compose.yml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    volumes:
      - pepe-data:/data
      - pepe-tools:/tools
    environment:
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?ponlo en el .env}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?ponlo en el .env}
      PHX_HOST: agents.example.com
      TZ: Europe/Madrid
    # No hay `ports:`: solo se publica Caddy. Pepe solo es alcanzable dentro de la red
    # interna, así que nadie puede saltarse el TLS golpeando el host directo en :4000.
    expose:
      - "4000"

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    depends_on:
      - pepe

volumes:
  pepe-data:
  pepe-tools:
  caddy-data:
```

```caddyfile
# Caddyfile
agents.example.com {
	reverse_proxy pepe:4000
}
```

```bash
docker compose up -d
```

Eso es el proxy inverso completo. Caddy solicita el certificado en la primera petición
que recibe y lo renueva él solo; los guarda en `caddy-data`, así que no borres ese
volumen sin pensarlo, o tendrás que pedirlos de nuevo y puedes toparte con el límite de
emisión de Let's Encrypt.

## Docker Swarm, detrás de Traefik

Si ya tienes un Swarm corriendo con Traefik, Pepe se suma como un servicio más. Solo dos
cosas se apartan de una stack cualquiera, y las dos tienen que ver con el estado que
vive en ese volumen.

```yaml
# pepe-stack.yml, desplegado con: docker stack deploy -c pepe-stack.yml pepe
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    volumes:
      - pepe_data:/data
      - pepe_tools:/tools
    environment:
      PEPE_DASHBOARD_PASSWORD: "${PEPE_DASHBOARD_PASSWORD:?}"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE:?}"
      PHX_HOST: agents.example.com
      TZ: Europe/Madrid
    networks:
      - network_public
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      # Contando la BEAM y las migraciones que corren al iniciar. Si el healthcheck
      # empieza a preguntar demasiado pronto, mete la tarea en un bucle de reinicios
      # que parece un crash.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # Por defecto, Swarm arranca la tarea nueva antes de apagar la vieja, y eso
        # dejaría dos Pepes sobre el mismo volumen mientras dura el despliegue.
        order: stop-first
        failure_action: rollback
      rollback_config:
        order: stop-first
      placement:
        # Los volúmenes locales no siguen a la tarea a otro nodo.
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.pepe.rule=Host(`agents.example.com`)"
        - "traefik.http.routers.pepe.entrypoints=websecure"
        - "traefik.http.routers.pepe.tls=true"
        - "traefik.http.routers.pepe.tls.certresolver=letsencryptresolver"
        - "traefik.http.services.pepe.loadbalancer.server.port=4000"
        - "traefik.docker.network=network_public"

networks:
  network_public:
    external: true

volumes:
  pepe_data:
  pepe_tools:
```

En Swarm, las labels de Traefik van bajo `deploy.labels`, no en el `labels:` propio del
servicio. Si las pones en el lugar equivocado, Traefik simplemente no ve el servicio
nunca: no hay error, solo un 404 para ese host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

Con Kamal, Pepe es la aplicación que se despliega. No hay nada que compilar, así que el
Dockerfile tiene una sola línea; existe solo para darle a Kamal algo que construir y
subir a tu propio registry, y también es donde agregarías paquetes de sistema si el
agente llegara a necesitarlos:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Fija una versión concreta, no `latest`. Kamal reconstruye en cada despliegue, y con
`latest` un deploy de un cambio tuyo que no tiene nada que ver terminaría trayendo, en
silencio, una versión distinta de Pepe.

```yaml
# config/deploy.yml
service: pepe
image: tu-usuario/pepe

servers:
  web:
    # Un solo host. Mira la nota de abajo.
    - 203.0.113.10

proxy:
  ssl: true
  host: agents.example.com
  app_port: 4000
  healthcheck:
    path: /healthz

env:
  clear:
    PHX_HOST: agents.example.com
    TZ: Europe/Madrid
  secret:
    - PEPE_DASHBOARD_PASSWORD
    - SECRET_KEY_BASE

volumes:
  - /opt/pepe/data:/data
  - /opt/pepe/tools:/tools
```

```bash
kamal setup     # la primera vez
kamal deploy    # a partir de ahí
```

El proxy de Kamal termina el TLS y obtiene el certificado a partir de `proxy.host`.

### El único valor por defecto que hay que cambiar

Por diseño, Kamal despliega sin downtime: arranca el contenedor nuevo, espera a que pase
el healthcheck, cambia el tráfico hacia él, y solo entonces apaga el viejo. Para una
aplicación cuya base de datos vive aparte, eso es exactamente lo que quieres.

Durante esos segundos hay dos Pepes activos al mismo tiempo. El nuevo todavía no atiende
tráfico, lo cual suena inofensivo, y para las peticiones lo es: el proxy no ha cambiado
todavía. Pero un scheduler no espera a que nadie le pida nada.

**Los crons, watches y compromisos disparan en ambas instancias.** Cada una arranca su
propio scheduler al iniciar, con un latido cada 30 segundos contra el mismo
`config.json`, y lo que evita que un trabajo corra dos veces es un estado en memoria
dentro de ese proceso puntual. Una segunda instancia tiene el suyo propio, vacío. Así
que cualquier cosa que venza durante la ventana de solapamiento corre dos veces: dos
turnos de agente facturados, dos mensajes entregados. El propio supervisor de Pepe lo
advierte entre paréntesis: *ejecuta una sola superficie de larga duración a la vez; dos
schedulers sobre una misma config disparan el doble.*

Para que conste, los almacenes de ese volumen son menos dramáticos de lo que parece.
SQLite se abre en modo WAL con busy timeout, y lo más probable es que aguante bien. El
almacén Mnesia puede reiniciarlo la instancia que lo encuentre sin cargar, pero es la
capa desechable por diseño: contexto de sesión con TTL y claves de dedupe, así que lo
que pierdes es el hilo de conversaciones abiertas, no algo que hayas configurado tú. Y
`config.json` solo pierde una escritura si la instancia vieja estaba escribiendo justo
en ese instante, algo que requiere tráfico que está a punto de dejar de recibir.

**Si esto te afecta depende de lo que ejecutes.** Hazte dos preguntas, y si respondes que
no a ambas, quédate con el despliegue sin downtime e ignora el resto de esta sección:
¿algo dispara por horario (crons, watches, compromisos)? ¿tienes un gateway de Telegram
configurado? Telegram es el caso que no depende de la suerte: las dos instancias hacen
polling sobre el mismo token de bot, una de ellas recibe un `409`, y un mensaje puede
terminar en manos de la instancia que está a punto de apagarse. Eso pasa en cada
despliegue, no de vez en cuando.

Si te aplica cualquiera de los dos casos, para la aplicación antes de desplegar y acepta
esa ventana corta:

```bash
kamal app stop
kamal deploy
```

Si ni siquiera esa ventana es aceptable, corre Pepe como **accessory** de Kamal en vez
de como aplicación. `kamal accessory reboot pepe` apaga el contenedor viejo antes de
levantar el nuevo, sin solapamiento, y un accessory nunca entra en el balanceo de carga.
Esa es también la forma natural de montarlo cuando Pepe va *junto a* una aplicación que
ya despliegas con Kamal, en vez de ser él mismo el despliegue.

## Healthchecks

`/healthz` (o `/health`) responde 200 en cuanto la aplicación arranca, y está exento a
propósito de la redirección a HTTPS, para que un proxy pueda alcanzarlo por HTTP interno
sin cifrar.

Dale un periodo de arranque generoso. Pepe corre sus migraciones al iniciar, y un check
que empieza a sondear a los 10 segundos en un host cargado puede matar un contenedor que
estaba a punto de quedar listo.

## No pongas HTTP basic auth por delante

Es el instinto natural cuando expones un servicio en un dominio propio, pero rompe tres
cosas a la vez. El panel ya tiene su propia contraseña, con página de acceso y limitador
de intentos, así que el basic auth no suma nada ahí; el problema es que también
terminaría cubriendo `/v1`, los endpoints de webhook a los que Telegram y WhatsApp
mandan sus POST, y el WebSocket del widget de chat. Los tres tienen su propia
credencial, y ninguno sabe qué hacer con el cuadro de contraseña que muestra el
navegador.

Si quieres una segunda cerradura solo para el panel, pon el basic auth únicamente en sus
rutas, y deja `/v1`, `/webhooks` y `/socket` tal cual.

## Cuando no arranca

Baja capa por capa; cada una deja un síntoma distinto:

* **`ERR_NAME_NOT_RESOLVED`**: problema de DNS, o una errata en el dominio. La petición
  nunca llegó a tu servidor.
* **404 desde el proxy**: la petición sí llegó, pero ninguna ruta coincidió. El `Host`
  configurado en el proxy no es el que estás pidiendo (o, en Swarm, las labels no
  quedaron bajo `deploy.labels`).
* **Un certificado autofirmado o por defecto**: el proxy tampoco tiene ruta para ese
  host, así que nunca llegó a pedir uno. Es la misma causa que el 404, vista desde la
  capa de TLS.
* **403 con una pantalla de bloqueo**: Pepe está respondiendo. Falta configurar la
  contraseña del panel.
* **400 "Host not allowed"**: Pepe está respondiendo, pero `allowed_hosts` no incluye el
  dominio que estás usando.
* **La pantalla de acceso, en cada despliegue**: `SECRET_KEY_BASE` no está definido.

`docker logs` sobre el contenedor te dice en una o dos líneas en cuál de estos casos
estás: si Pepe registró `Access PepeWeb.Endpoint at ...`, la aplicación está bien y el
problema está en algo delante de ella.
