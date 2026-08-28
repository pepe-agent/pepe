---
title: Navegador
description: Un agente puede manejar un navegador real sin interfaz gráfica para páginas que exigen JavaScript, inicio de sesión o completar un flujo a base de clics.
---

`fetch_url` es un simple GET por HTTP, así que no puede ejecutar JavaScript, iniciar sesión ni hacer clic en nada. Para eso está la herramienta `browser`: un Chrome real, sin interfaz, que se maneja página por página y que persiste entre llamadas dentro de la misma conversación hasta que lo cierras.

Cada conversación arranca su propia sesión de navegador la primera vez que llama a `open`, y esa sesión se cierra sola tras diez minutos de inactividad si nadie la termina antes. Las cookies y la página actual se conservan de una llamada a la siguiente, de modo que un inicio de sesión, un formulario de varios pasos o una página que solo revela su contenido después de un clic funcionan igual que en una pestaña real.

## Qué puede hacer

- **`open`**: navega a una URL (arrancando el navegador de la sesión si todavía no hay ninguno corriendo). Devuelve el título de la página, su texto visible y una lista numerada de los elementos sobre los que se puede actuar.
- **`snapshot`**: vuelve a describir la página actual con el mismo formato que `open`, pero sin navegar. Sirve para cuando un script de la página cambia algo sin recargarla por completo.
- **`click`**: hace clic en el elemento numerado `ref` del último `open` o `snapshot`.
- **`type`**: escribe texto en el elemento numerado `ref`.
- **`press`**: pulsa una tecla del teclado (por ejemplo, "Enter"), enfocando antes un elemento si hace falta.
- **`close`**: termina la sesión y libera el navegador.

```
Tú: Entra a la página de estado y dime si algo está caído.

Agente: [browser open: "https://status.example.com/login"]
        [browser type ref=2: "el correo de la cuenta"]
        [browser type ref=3: "la contraseña de la cuenta"]
        [browser click ref=4]
        [browser snapshot]
Todo en verde, sin incidentes abiertos ahora mismo.
```

Los elementos se identifican por número, no con un selector CSS que tendrías que escribir a mano. Cada `open` o `snapshot` etiqueta todo elemento clicable o completable y devuelve qué es y qué dice, así que el agente lee directamente "el elemento 4 es el botón de enviar" a partir de lo que se le acaba de mostrar.

## Postura de seguridad

Un navegador bajo el control de un agente accede a la misma red que la aplicación, así que `browser` aplica la misma regla que `fetch_url`: solo `http` o `https`, nunca una dirección interna o privada (loopback, RFC1918, link-local, metadatos de la nube). Esa comprobación no se limita a la URL que le pasas a `open`. Un enlace de la propia página, una redirección de JavaScript, el envío de un formulario o las peticiones que la página hace en segundo plano se revisan de la misma forma, y se bloquean antes de que Chrome llegue siquiera a enviarlos, no solo la dirección que tú escribiste. Y porque un navegador real es una superficie mucho más amplia que una herramienta de solo lectura (corren los scripts propios de la página, una sesión iniciada podría quedar expuesta, y se consume CPU y memoria de verdad), `browser` nunca se considera segura por defecto: cada llamada pasa por el mismo aviso de permiso que `bash`.

## Cómo consigue un navegador

`browser` necesita un binario real de Chrome, Chromium, Edge o Brave para manejar. Lo busca en este orden:

1. `PEPE_CHROME_BINARY`, si lo defines: una ruta explícita gana sobre cualquier otra opción.
2. Lo que ya tengas instalado, revisando el `PATH` y las ubicaciones habituales de cada sistema operativo (`/Applications` en macOS, `Program Files` y la carpeta de instalación por usuario en Windows), de modo que un navegador que ya tienes se usa tal cual, esté en un contenedor o no.
3. **Una descarga automática única**, si ninguna de las anteriores encontró nada: un build pequeño y sin interfaz de `chrome-headless-shell`, tomado del feed oficial Chrome for Testing de Google y guardado en caché bajo `~/.cache/pepe/browser/` para que esto solo ocurra una vez por máquina. Desactívalo con `PEPE_BROWSER_AUTO_DOWNLOAD=0` si prefieres instalar tú mismo un navegador y recibir un error claro en su lugar.

La imagen por defecto no trae el paquete del navegador (el mismo criterio que deja fuera a ffmpeg; consulta el Dockerfile), pero sí incluye las bibliotecas compartidas que necesita un navegador descargado para poder arrancar, en las dos arquitecturas que publica la imagen oficial (`amd64` y `arm64`), ya que `browser` es una herramienta integrada y no un extra opcional. Por eso el paso 3 es lo que corre por defecto en Docker, y funciona sin nada más: sin build arg, sin instalación manual, en cualquiera de las dos arquitecturas, incluido un Mac con Apple Silicon o un host ARM en la nube, no solo `amd64`. Si prefieres empaquetar un navegador completo dentro de la imagen en vez de descargarlo en tiempo de ejecución:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Fuera de Docker en Linux

Un navegador descargado necesita bibliotecas compartidas que el sistema operativo debe proveer, y fuera de Docker eso no está garantizado como sí lo está en la imagen oficial: una distribución de escritorio suele tenerlas ya (otras aplicaciones con interfaz gráfica dependen de las mismas bibliotecas), pero un servidor mínimo o sin interfaz puede que no. Si `browser` descarga el navegador correctamente pero falla al arrancarlo, ejecuta:

```
mix pepe browser install
```

El comando detecta tu gestor de paquetes (`apt`, `dnf`, `yum`, `pacman`, `apk` o `zypper`) e instala a través de él un navegador completo, pidiendo tu contraseña de `sudo` si la necesita: al fin y al cabo eso fue justo lo que pediste al ejecutarlo. Una vez instalado, `browser` lo encuentra directamente en el `PATH` y deja de descargar nada.

## Linux en ARM

Google no publica un build de Chrome for Testing para Linux en ARM, así que ahí el paso 3 recurre al propio CDN de Playwright (una descarga HTTPS normal, igual que Chrome for Testing, sin npm ni Node.js de por medio). La única diferencia es que descarga el Chromium completo en lugar del build más liviano sin interfaz, porque ese CDN no ofrece la versión headless como artefacto aparte. En cualquier caso, todo esto es automático: un host ARM no necesita ninguna configuración especial, ni dentro de Docker ni fuera de él.
