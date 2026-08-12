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

Dos vías, según de dónde venga. Un agente con la herramienta `manage_skill` la
usa para todo lo que el marketplace pueda resolver: un nombre en el registro
incluido o en un tap, o una referencia de [PepeHub](https://hub.pepe-agent.com)
(`@handle/nombre`, o la URL de su propia página). Es la misma instalación
consciente del registro que hace `mix pepe skill install`, con la confianza y
la procedencia registradas de la misma forma. Para una fuente sin ninguna
entrada en registro (una URL suelta, un gist, un repositorio aislado), la
skill `install-skill` enseña al agente a traerla a mano. En ambos casos, el
texto de una skill externa es entrada no confiable: el agente lo escanea con
la herramienta `scan_skill` antes de escribirlo en disco. El escaneo señala
inyección de prompt, exfiltración de secretos, comandos destructivos,
persistencia y ofuscación: una segunda comprobación, no un sustituto de leer
el contenido, y nunca instala nada por su cuenta.

## Instalar desde un marketplace

`manage_skill` (arriba) es la vía conversacional para todo lo que los
registros/PepeHub puedan resolver. `mix pepe skill` es la vía del operador
hacia los mismos registros, con la misma búsqueda e historia de actualización:

```bash
pepe skill search release            # busca en cada tap más el registro incluido
pepe skill install cut-a-release     # instala por nombre
pepe skill install @jhonathas/google-workspace   # o una referencia de PepeHub (ver abajo)
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # o directamente
pepe skill update cut-a-release      # vuelve a traerla desde la fuente exacta de la que se instaló
pepe skill tap add https://github.com/tu-equipo/pepe-skills   # añade un registro más allá del incluido
```

Un nombre con la forma `@handle/nombre` (o la URL de la propia página del
paquete, copiada directamente de [PepeHub](https://hub.pepe-agent.com))
resuelve contra PepeHub directamente, el registro de plugins/skills de Pepe,
en vez del registro incluido o de un tap: se comprueba primero, ya que
ninguna entrada incluida o de tap usa esa forma. Se instala bajo el slug
simple del paquete (`google-workspace`, no `@jhonathas/google-workspace`), el
nombre que usan el resto de comandos de skill y la herramienta `skill`.
Apuntar `skill install` a un nombre que en realidad es un plugin en PepeHub,
no una skill, falla con un mensaje claro que indica usar `plugin install` en
su lugar.

Cada instalación pasa por el mismo escaneo de seguridad estático que usan
`manage_skill`/`install-skill`; un veredicto peligroso se rechaza a menos que
pases `--force`. La confianza es `"official"` para el registro incluido en el
propio repositorio (curado por quienes mantienen Pepe) y para un paquete de
PepeHub que el propio PepeHub haya marcado manualmente como oficial. Todo lo
resuelto a través de un tap que hayas añadido, un paquete de PepeHub sin esa
marca, o instalado con `--source`, es `"community"`: cuando un agente lo lee
con la herramienta `skill`, su contenido se envuelve en el mismo marcador de
contenido no confiable que lleva una página web obtenida, hasta que tú mismo
la hayas revisado.

`update` queda fijado a la fuente exacta desde la que se instaló una skill —si el registro de
un tap más tarde apunta ese nombre a una fuente *distinta*, `update` se niega en vez de
seguirla en silencio. Una skill con el mismo nombre desde otro lado solo puede reemplazar una
ya instalada mediante un `install --force` explícito, nunca una actualización rutinaria.

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
