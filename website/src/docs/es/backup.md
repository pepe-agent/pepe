---
title: Copia de seguridad y extracción
description: Archiva la instalación completa, o saca una empresa para que funcione en su propio servidor, y restaura cualquiera de las dos con un solo comando.
---

Todo lo que Pepe sabe vive como archivos bajo `~/.pepe/` (o `PEPE_HOME`), así que moverlo es mover un directorio. Dos comandos crean un archivo comprimido de ello, y uno restaura cualquiera de los dos.

## Copia de seguridad: la instalación completa

```bash
pepe backup                       # genera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /ruta/x.tgz
```

Este es el archivo del tipo «no pierdas esta máquina». Empaqueta todas las empresas, todos los espacios de trabajo de los agentes, el espacio compartido, las sesiones y los libros de uso, y omite `data/mnesia/` (una caché desechable que se reconstruye sola). Restaurado en una máquina vacía, es la misma máquina otra vez.

## Extracción: una empresa, por su cuenta

```bash
pepe extract acme                 # genera acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /ruta/acme.tgz
```

Una empresa que creció dentro de una instalación compartida puede irse para funcionar en su propio servidor. No se llega ahí copiando una carpeta, porque los registros de esa empresa están entretejidos en el `config.json` compartido como identificadores `acme/agente`. La extracción reescribe esos identificadores a nombres de raíz simples, así que el archivo es una **instalación nueva de un solo inquilino que resulta ser esa empresa**: colócalo en un servidor nuevo y ejecútalo.

Solo esa empresa viaja: sus agentes, modelos, crons, watches, bots, tokens, espacios de trabajo e historial de uso. Nada de los demás inquilinos va con ella. Si uno de sus agentes depende de un **modelo compartido** (uno que vive en la raíz, no dentro de la empresa), ese modelo también se incorpora al archivo, para que el paquete funcione en una máquina vacía; el comando te dice cuáles.

## Restauración: cualquiera de los archivos

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

Una copia de seguridad y una extracción tienen la misma forma —un `~/.pepe` dentro de un tarball—, así que un solo comando restaura ambas. Se descomprime en `~/.pepe` (o `PEPE_HOME`). Como una restauración **reemplaza** lo que hay, se niega a escribir sobre un directorio no vacío a menos que pases `--force`.

## Los secretos nunca están en el archivo

Los secretos son referencias `${ENV_VAR}`, resueltas al momento de la lectura, así que viven en tu entorno y nunca en los archivos (consulta [Secretos](/es/docs/secrets/)). Eso significa que **no** están en una copia de seguridad ni en una extracción, por diseño. Cada uno de estos comandos imprime las variables que el archivo referencia y si cada una está definida en este momento, para que puedas aprovisionarlas en el destino. Vuelve a exportarlas allí y la configuración se resuelve; olvida una y aquello que desbloqueaba simplemente no estará.
