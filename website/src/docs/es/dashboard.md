---
title: Panel
description: Usa la interfaz web local para inspeccionar y gestionar agentes, modelos, canales y ejecuciones.
---

El panel es la interfaz web local que arranca con `pepe serve`. Úsalo para conversar con agentes, inspeccionar trazas, gestionar conexiones de modelo, configurar canales, revisar tareas programadas y generar tokens de API sin editar JSON a mano.

## Mantenerlo en marcha

`pepe serve` corre en primer plano - cerrar la terminal o salir de la sesión detiene el proceso, y el panel con él. Para un despliegue de verdad, instálalo como servicio persistente en segundo plano: launchd en macOS, systemd `--user` en Linux. Sobrevive a cierre de sesión/reinicio y se reinicia solo si falla.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Solo funciona desde el binario `pepe` instalado, no con `mix pepe serve install`. Si tus conexiones de modelo referencian secretos `${ENV_VAR}`, `install` los lista - el servicio arranca con un entorno mínimo, así que hay que añadirlos a mano en el archivo generado.

## Acceso al panel

El panel web está abierto en localhost por defecto, lo que resulta cómodo para el desarrollo local. En el momento en que lo expones más allá de tu máquina, ponlo detrás de una contraseña:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Puedes pasar una contraseña literal o una referencia `${ENV_VAR}` para que el secreto quede fuera del archivo. Una vez definida la contraseña, el panel exige iniciar sesión en `/login`. Bórrala con `pepe dashboard password --clear`.

La contraseña se lee de `dashboard.password` en la configuración (interpolada), con respaldo en la variable de entorno `PEPE_DASHBOARD_PASSWORD`. Dos ajustes relacionados endurecen un panel servido detrás de un dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define los valores adicionales del encabezado `Host` que el panel acepta. Esto sirve también como lista blanca contra el reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista los proxies inversos cuyo encabezado `X-Forwarded-For` puede considerarse confiable. Vacío por defecto, lo que significa que no se confía en ningún encabezado de reenvío.

Vinculado a una interfaz pública sin contraseña, el panel se cierra por defecto y bloquea a los clientes remotos hasta que definas una.
