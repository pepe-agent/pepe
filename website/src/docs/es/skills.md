---
title: Skills
description: Instala instrucciones reutilizables que enseñan flujos de trabajo repetibles a los agentes.
---

Una skill es un documento de instrucciones bajo demanda: un archivo Markdown que
enseña al agente un *procedimiento*, como instalar una herramienta o cómo tratar
un mensaje de audio. Así es como un agente aprende algo nuevo sin que cambie una
sola línea de código.

## Listadas, no cargadas

Una skill nunca se pega entera en el prompt del sistema. Solo su nombre y un
resumen de una línea aparecen en el contexto del agente. Cuando el tema surge, el
agente llama a la herramienta `skill` con ese nombre, lee el documento completo y
lo sigue.

Esa indirección es justo lo que importa. Un agente puede llevar decenas de
procedimientos pagando solo una línea de contexto por cada uno, y abre la versión
larga exactamente cuando el trabajo lo pide. El resumen es la primera línea no
vacía del archivo, así que esa línea de apertura debe decir cuándo se aplica la
skill.

<div class="note"><strong>La herramienta skill.</strong> El agente necesita la herramienta <code>skill</code> en su lista de herramientas para leer skills. Sin ella, las skills quedan listadas en el contexto pero nunca se abren.</div>

## Skills integradas

Estas vienen con Pepe, en `priv/skills/`:

- **`skill-creator`** - cómo crear, editar, auditar y mejorar skills (la meta-skill).
- **`install-tool`** - escribir una herramienta en un plugin y activarla por chat.
- **`write-a-script`** - resolver tareas complejas escribiendo y guardando un programa para ejecutar.
- **`manage-routing`** - cambiar las rutas entre agentes con `set_route`.
- **`handle-media`** - entender una entrada de voz, audio, imagen o archivo (transcribir, leer), instalando lo que haga falta.
- **`install-skill`** - instalar una skill desde una URL, un gist, un repositorio u otro Pepe.
- **`create-watch`** - crear un watch duradero del tipo "comprueba X y avísame cuando ocurra".

## Escribir las tuyas

Las skills del usuario viven en `~/.pepe/skills/*.md`. Una skill del usuario
sustituye a la integrada del mismo nombre, así que escribir tu propio
`handle-media.md` reemplaza al que viene con Pepe. La primera línea no vacía es
el resumen; todo lo demás es el procedimiento, en Markdown puro, escrito para que
el agente lo lea y lo siga.

```bash
~/.pepe/skills/publicar-release.md
```

No hay paso de registro ni reinicio. Basta con dejar el archivo ahí y la skill
aparece en la lista del agente en su siguiente mensaje.

### Deja que el agente la escriba

Un agente puede escribir sus propias skills. Pídele que recuerde como skill la
forma de hacer algo y, guiado por `skill-creator`, escribe un nuevo
`skills/<nombre>.md` que aparece de inmediato en su propia lista.

> Tú: funcionó. recuerda como skill el proceso de publicar una release
>
> Agente: guardé skills/publicar-release.md. Lo seguiré la próxima vez que pidas una release.

Esto es lo que hace duradero el conocimiento del agente. El procedimiento que
resolvió una vez queda escrito, en lugar de redescubrirse en cada sesión.

### Instalar una de fuera

La skill `install-skill` enseña al agente a traer una skill desde una URL, un
gist, un repositorio u otra instancia de Pepe. El texto de una skill externa es
entrada no confiable, así que el agente lo escanea con la herramienta
`scan_skill` antes de escribirlo en disco. El escaneo señala inyección de prompt,
exfiltración de secretos, comandos destructivos, persistencia y ofuscación. Es
una segunda comprobación, no un sustituto de leer el contenido, y nunca instala
nada por su cuenta.

## Skills, plugins y scripts

Los tres puntos de extensión se componen, y juntos son lo que permite pedirle a
un agente, en lenguaje natural, algo que todavía no sabe hacer.

Combinado con [plugins](../plugins/) y `enable_tool`, puedes pedirle por chat al
agente que instale una herramienta que haga X. Lee la skill `install-tool`,
escribe el plugin en `plugins/<nombre>.exs`, activa la herramienta en sí mismo y
empieza a usarla, sin reiniciar.

Para trabajo complejo o de varios pasos, el agente no lo hace todo a mano. La
herramienta `run_script` le permite escribir un programa corto (Python, Node,
Ruby, Bash o Elixir, y Elixir siempre está disponible) y ejecutarlo, recibiendo
de vuelta stdout, stderr y el código de salida para iterar sobre los errores. Los
scripts que valen la pena se guardan en `scripts/` y se reejecutan más tarde
pasándole a `run_script` una referencia `file:`. Cuando el agente descubre *cómo*
hacer una tarea recurrente, leer un PDF o procesar una hoja de cálculo, se
escribe a sí mismo una skill en `skills/<nombre>.md`. La skill `write-a-script`
enseña todo ese ciclo.
