---
title: Desplegar en un servidor
description: Pon Pepe en un servidor con dominio y TLS, usando Docker Compose, Docker Swarm o Kamal.
---

[Docker](/es/docs/docker/) cubre el contenedor en sí. Esta página cubre el paso
siguiente: ponerlo en una máquina a la que llega otra gente, con dominio y certificado.

Sea cual sea la herramienta, el contenedor es el mismo y los dos volúmenes también. Lo que
cambia es todo lo que hay alrededor, y lo que cambia no es obvio, porque en local son
todos valores por defecto en los que nunca tuviste que pensar.

## Cuatro cosas que cambian en cuanto sale de localhost

**La contraseña del panel pasa a ser obligatoria.** Ya lo era en Docker, y la razón es la
misma aquí: Pepe trata todo lo que no sea loopback como red pública y devuelve 403 a cada
petición sin ella. Detrás de un proxy inverso, eso es *cada* petición.

**`PHX_HOST` es el nombre público.** Pepe construye URLs absolutas a partir de él: los
embeds del widget y las URLs de webhook que le das a Telegram o a WhatsApp. Sin definir
queda en `localhost`, y esas URLs quedan silenciosamente mal mientras todo lo demás
funciona.

**`SECRET_KEY_BASE`, o todo el mundo pierde la sesión en cada despliegue.** Sin él, Pepe
genera uno aleatorio en cada arranque, lo que sirve para un contenedor suelto y está mal
para un servidor: las cookies de sesión firmadas con el secreto anterior dejan de validar.
Genéralo una vez (`openssl rand -base64 48`) y consérvalo.

**Dos ajustes viven solo en `config.json`.** No tienen variable de entorno, así que se
aplican después del primer arranque, no se pasan al levantarlo:

```bash
docker exec -it <contenedor> bin/pepe rpc '
  Pepe.Config.update(fn c ->
    c
    |> put_in(["dashboard", "allowed_hosts"], ["agents.example.com"])
    |> put_in(["dashboard", "trusted_proxies"], ["10.0.1.0/24"])
  end)'
```

`allowed_hosts` cierra el DNS rebinding: con contraseña puesta y sin lista de permitidos,
Pepe acepta cualquier `Host`, porque la contraseña es el cerrojo y no tiene manera de
saber qué dominio querías. `trusted_proxies` es el que la gente se salta y luego
diagnostica mal: sin él se ignora todo `X-Forwarded-For`, así que el limitador de intentos
de acceso ve la dirección del proxy para todo el mundo e internet entera comparte un solo
cubo. Usa la red en la que tu proxy está de verdad, no `0.0.0.0/0`. Confiar en cualquier
cabecera de reenvío es lo mismo que no tener limitador.

<div class="note"><strong>Una réplica. Siempre.</strong> De los dos almacenes que Pepe mantiene en ese volumen, el riesgo no es tanto el estado que guarda. Es que una segunda instancia ejecuta un segundo scheduler, y cada cron, watch y compromiso dispara dos veces (la <a href="#el-único-valor-por-defecto-que-hay-que-cambiar">sección de Kamal</a> lo desarrolla, y vale para todas las herramientas de aquí). Dos contenedores en dos volúmenes son peores de un modo más silencioso: dos Pepes distintos, cada uno convencido de que es el único. Todos los ejemplos de abajo fijan una réplica, y donde el comportamiento por defecto del orquestador es arrancar el contenedor nuevo antes de parar el viejo, eso también se desactiva.</div>

## Docker Compose, detrás de Caddy

Lo más pequeño que funciona en una sola máquina. Caddy consigue el certificado por su
cuenta, sin más configuración que el nombre del dominio.

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
    # Sin `ports:`. Solo Caddy se publica; Pepe es alcanzable en la red interna y en
    # ningún otro sitio, así que nadie puede saltarse el TLS pegándole al host en :4000.
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

Ese es el proxy inverso entero. Caddy pide el certificado en la primera petición y lo
renueva solo; `caddy-data` es donde los guarda, así que no borres ese volumen a la ligera
o volverás a pedirlos todos y puedes chocar con el límite de emisión de Let's Encrypt.

## Docker Swarm, detrás de Traefik

Si ya tienes un Swarm con Traefik, Pepe entra en él como cualquier otro servicio. Dos
cosas difieren de una stack normal, y las dos son por el estado en ese volumen.

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
      # La BEAM más las migraciones al arrancar. Un healthcheck que dispara demasiado
      # pronto mete la tarea en un bucle de reinicios con pinta de crash.
      start_period: 90s
    deploy:
      replicas: 1
      update_config:
        # Por defecto Swarm arranca la tarea nueva antes de parar la vieja, lo que
        # pondría dos Pepes en un volumen durante todo el despliegue.
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

En Swarm las labels de Traefik van bajo `deploy.labels`, no bajo el `labels:` del propio
servicio. En el sitio equivocado, Traefik sencillamente nunca ve el servicio: ningún
error, solo un 404 para ese host.

```bash
export PEPE_DASHBOARD_PASSWORD='...' SECRET_KEY_BASE="$(openssl rand -base64 48)"
docker stack deploy -c pepe-stack.yml pepe
```

## Kamal

Kamal despliega Pepe como la aplicación. No hay nada que compilar, así que el Dockerfile
tiene una línea. Existe para que Kamal tenga algo que construir y subir a tu propio
registry, y es también donde van los paquetes de sistema, si el agente acaba necesitando
alguno:

```dockerfile
# Dockerfile
FROM ghcr.io/pepe-agent/pepe:0.10.2
```

Fija una versión en vez de `latest`. Kamal reconstruye en cada despliegue, y `latest`
significaría que un despliegue de un cambio tuyo sin relación alguna se trae un Pepe nuevo
con él, en silencio.

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

El proxy de Kamal termina el TLS y consigue el certificado a partir de `proxy.host`.

### El único valor por defecto que hay que cambiar

Kamal despliega sin caída por diseño: arranca el contenedor nuevo, espera a que responda al
healthcheck, mueve el tráfico hacia él y solo entonces para el viejo. Para una aplicación
cuya base de datos vive en otro sitio, eso está exactamente bien.

Durante esos pocos segundos hay dos Pepes en pie a la vez. El nuevo todavía no está sirviendo
nada, lo que suena inofensivo, y para las peticiones lo es: el proxy aún no ha cambiado. Pero
un scheduler no espera a que le pidan.

**Los crons, watches y compromisos disparan en los dos.** Cada instancia arranca su propio
scheduler al iniciar, latiendo cada 30 segundos contra el mismo `config.json`, y el claim que
impide que un trabajo corra dos veces es estado en memoria dentro de ese proceso. Un segundo
proceso tiene el suyo, vacío. Así que todo lo que venza en la ventana corre dos veces: dos
turnos de agente facturados, dos mensajes entregados. El propio supervisor de Pepe lo dice,
entre paréntesis: *ejecuta una sola superficie de larga duración a la vez, dos schedulers
sobre una config disparan doble.*

Los almacenes del volumen son menos dramáticos de lo que parecen, para que conste. SQLite se
abre en WAL con busy timeout y lo más probable es que aguantara. El almacén Mnesia puede
reiniciarlo la instancia que lo encuentre sin cargar, pero es la capa desechable por diseño:
contexto de sesión bajo TTL y claves de dedupe, así que pierdes el hilo de las conversaciones
abiertas, no algo que hayas configurado. Y `config.json` solo pierde una escritura si la
instancia vieja está haciendo una en ese instante exacto, lo que requiere tráfico que está a
punto de dejar de recibir.

**Que eso importe depende de lo que ejecutes.** Dos preguntas, y si las dos respuestas son no,
quédate con el despliegue sin caída e ignora esta sección: ¿hay algo que dispare por horario
(crons, watches, compromisos), y hay un gateway de Telegram configurado? Telegram es el que no
depende de la suerte: las dos instancias hacen polling sobre el mismo token de bot, una recibe
un `409`, y un mensaje puede acabar en manos justamente de la instancia que está a punto de
pararse. Eso pasa en cada despliegue, no en algunos.

Si aplica cualquiera de los dos, para la aplicación antes y acepta la ventana corta:

```bash
kamal app stop
kamal deploy
```

Si la ventana no es aceptable, ejecuta Pepe como **accessory** de Kamal. `kamal accessory
reboot pepe` para el contenedor viejo antes de arrancar el nuevo, sin solapamiento, y un
accessory nunca entra en el balanceo. Ese es también el formato natural cuando Pepe va *al
lado* de una aplicación que ya despliegas con Kamal, en vez de ser él el despliegue.

## Healthchecks

`/healthz` (o `/health`) responde 200 en cuanto la aplicación está en pie, y está
deliberadamente exento de la redirección a HTTPS, para que un proxy pueda alcanzarlo por
HTTP interno plano.

Dale un periodo inicial generoso. Pepe corre sus migraciones al arrancar, y un check que
empieza a sondear a los 10 segundos en un host cargado mata un contenedor que estaba a
punto de estar bien.

## No pongas HTTP basic auth delante

Es un instinto natural para un servicio en un dominio, y rompe tres cosas a la vez. El
panel ya tiene su propia contraseña, con página de acceso y limitador de intentos, así que
el basic auth no añade nada ahí, pero además se sienta encima de `/v1`, de los endpoints
de webhook a los que Telegram y WhatsApp hacen POST, y del WebSocket del widget de chat.
Los tres llevan su propia credencial y ninguno sabe responder a un cuadro de contraseña
del navegador.

Si quieres un segundo cerrojo en el panel en concreto, pon el basic auth solo en sus
rutas, y deja `/v1`, `/webhooks` y `/socket` en paz.

## Cuando no levanta

Ve bajando por las capas; cada una tiene un síntoma distinto:

* **`ERR_NAME_NOT_RESOLVED`**: DNS, o una errata en el dominio. Nada llegó a tu servidor.
* **404 desde el proxy**: la petición llegó y ninguna ruta encajó. El `Host` en la
  configuración del proxy no es el que se está pidiendo (o, en Swarm, las labels no están
  bajo `deploy.labels`).
* **Un certificado autofirmado o por defecto**: el proxy tampoco tiene ruta para ese host,
  así que nunca pidió uno. Misma causa que el 404, vista desde la capa de TLS.
* **403 con una página de candado**: Pepe está respondiendo. Falta la contraseña del panel.
* **400 "Host not allowed"**: Pepe está respondiendo y `allowed_hosts` no incluye el
  dominio que estás usando.
* **La pantalla de acceso, en cada despliegue**: `SECRET_KEY_BASE` no está definido.

`docker logs` en el contenedor te dice en una o dos líneas en cuál de estos casos estás:
si Pepe registró `Access PepeWeb.Endpoint at ...`, la aplicación está bien y el problema
está delante de ella.
