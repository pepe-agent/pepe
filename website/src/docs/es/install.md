---
title: Instalación
description: Instala Pepe y corre la configuración guiada antes de crear agentes.
---

Instala el binario `pepe` y luego ejecuta la configuración guiada: crea el
archivo de configuración, conecta un modelo y arma tu primer agente.

## 1. Instalación

Con un solo comando queda instalado el binario `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Confirma que se instaló bien:

```bash
pepe help
```

Pepe guarda toda su configuración en `~/.pepe/config.json`; no hace falta
levantar ninguna base de datos.

## 2. Configuración guiada (el camino rápido)

`pepe setup` te acompaña paso a paso por todo el proceso: iniciar sesión con
tu proveedor de modelo, elegir uno, crear tu primer agente y, si quieres,
conectar un canal.

```bash
pepe setup
```

Si prefieres hacerlo a mano, recurre a las páginas de modelos, agentes y
canales; cualquiera de los dos caminos termina escribiendo la misma
configuración.

<div class="note"><strong>Los secretos nunca quedan en el archivo.</strong> Cuando Pepe te pide una clave de API, acepta una referencia <code>${ENV_VAR}</code>, por ejemplo <code>${OPENROUTER_API_KEY}</code>, y eso es justamente lo que termina escrito en <code>~/.pepe/config.json</code>. El valor real se lee de tu entorno en el momento de ejecutar, y nunca se guarda ya expandido.</div>

## Docker

¿Prefieres un contenedor? Corre `docker pull ghcr.io/pepe-agent/pepe` (hay
imagen para amd64 y arm64). Va a pedirte un volumen y una contraseña para el
panel; ambos puntos, junto con cómo darle al agente herramientas extra dentro
del contenedor, están cubiertos en la [página de Docker](/es/docs/docker/).

## Desinstalar

Elimina el binario; si además quieres descartar cada modelo, agente y
credencial que hayas configurado, borra también la carpeta de configuración.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # opcional, también descarta tu configuración
```

(`~/.local/bin` es la carpeta de instalación por defecto; si la cambiaste con
`$PEPE_BIN_DIR`, será la que hayas apuntado ahí.)
