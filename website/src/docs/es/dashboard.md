---
title: Panel
description: Usa la interfaz web local para inspeccionar y gestionar agentes, modelos, canales y ejecuciones.
---

El panel es la interfaz web local que arranca con `pepe serve`. Úsalo para conversar con agentes, inspeccionar trazas, gestionar conexiones de modelo, configurar canales, revisar tareas programadas y generar tokens de API sin editar JSON a mano.

## Mantenerlo en marcha

`pepe serve` se ejecuta en primer plano: cerrar la terminal o salir de la sesión detiene el proceso, y el panel con él. Para un despliegue de verdad, instálalo como servicio persistente en segundo plano: launchd en macOS, systemd `--user` en Linux. Sobrevive a cierre de sesión/reinicio y se reinicia solo si falla.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Solo funciona desde el binario `pepe` instalado, no con `mix pepe serve install`. Si tus conexiones de modelo referencian secretos `${ENV_VAR}`, `install` los lista: el servicio arranca con un entorno mínimo, así que hay que añadirlos a mano en el archivo generado.

## Acceso al panel

El panel web está abierto en localhost por defecto, lo que resulta cómodo para el desarrollo local. En el momento en que lo expones más allá de tu máquina, ponlo detrás de una contraseña:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Puedes pasar una contraseña literal o una referencia `${ENV_VAR}` para que el secreto quede fuera del archivo. Una vez definida la contraseña, el panel exige iniciar sesión en `/login`. Bórrala con `pepe dashboard password --clear`.

La contraseña se lee de `dashboard.password` en la configuración (interpolada), con respaldo en la variable de entorno `PEPE_DASHBOARD_PASSWORD`. Dos ajustes relacionados endurecen un panel servido detrás de un dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define los valores adicionales del encabezado `Host` que el panel acepta. Esto sirve también como lista blanca contra el DNS rebinding.
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista los proxies inversos cuyo encabezado `X-Forwarded-For` puede considerarse confiable. Vacío por defecto, lo que significa que no se confía en ningún encabezado de reenvío.

Vinculado a una interfaz pública sin contraseña, el panel se cierra por defecto y bloquea a los clientes remotos hasta que definas una.

## Acceso remoto

Para llegar al panel o a la API desde fuera de tu máquina sin abrir un puerto ni montar un proxy inverso, `pepe serve` puede abrir un túnel de [Cloudflare](https://www.cloudflare.com/) (necesita `cloudflared` instalado):

```bash
pepe serve --tunnel
```

Es un **túnel rápido**: imprime una URL aleatoria `https://<algo>.trycloudflare.com` que solo dura mientras el proceso está en marcha y cambia cada vez. No hace falta cuenta de Cloudflare.

Para una **URL fija que tú eliges** en tu propio dominio, usa un túnel con nombre. Dos formas:

```bash
# Sin navegador (ideal en un servidor): crea el túnel y su hostname público en el
# panel de Cloudflare Zero Trust, apunta su servicio a http://localhost:4000,
# copia el token del conector y luego:
pepe serve --tunnel --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

# O con un inicio de sesión único en el navegador (guarda un cert.pem), sin token:
cloudflared tunnel login
pepe serve --tunnel --hostname pepe.example.com
```

Con `--token`, el hostname y su mapeo de servicio viven en el panel de Cloudflare; ahí `--hostname` es opcional, solo para imprimir la URL al arrancar. El token es un secreto, así que pásalo como referencia `${ENV_VAR}`. Una petición por el túnel siempre se trata como pública, así que define una contraseña del panel antes de depender de cualquiera de estos modos.
