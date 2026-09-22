---
title: Skills
description: Instala instrucciones reutilizables que le enseñan a los agentes flujos de trabajo repetibles.
---

Una skill es un documento de instrucciones que se consulta bajo demanda: un archivo
Markdown que le enseña a un agente un *procedimiento*, por ejemplo cómo instalar una
herramienta o cómo tratar un mensaje de audio. Así es como un agente aprende algo nuevo
sin que cambie ni una línea de código.

## Se listan, no se cargan

Una skill nunca se pega completa dentro del prompt del sistema. En el contexto del agente
solo aparecen su nombre y un resumen de una línea. Cuando el tema realmente surge, el
agente llama a la herramienta `skill` con ese nombre, lee el documento entero, y lo sigue.

Ese nivel de indirección es justo lo que mantiene todo esto barato. Un agente puede
conocer decenas de procedimientos sin que eso pese en la conversación, porque cada uno le
cuesta apenas una línea hasta el momento en que el trabajo de verdad lo requiere. El
resumen es simplemente la primera línea no vacía del archivo, así que esa primera línea
tiene que dejar claro cuándo aplica la skill, a menos que la skill declare ese resumen
en una cabecera de metadatos, en cuyo caso ese es el que gana: eso es lo que hace que
una skill escrita en otra herramienta funcione aquí tal cual, sin conversión (ver "Un
formato que otras herramientas comparten", más abajo).

<div class="note"><strong>La herramienta skill.</strong> El agente necesita tener <code>skill</code> en su lista de herramientas para poder leerlas. Sin ella, las skills quedan listadas en su contexto pero nunca llega a abrirlas.</div>

## Skills incluidas

Estas vienen de fábrica con Pepe, bajo `priv/skills/`:

- **`skill-creator`**: cómo crear, editar, auditar y mejorar skills; la meta-skill.
- **`install-tool`**: escribir una herramienta como plugin y activarla desde el chat.
- **`write-a-script`**: resolver tareas complejas escribiendo un programa y
  ejecutándolo.
- **`manage-routing`**: cambiar rutas entre agentes usando `set_route`.
- **`handle-media`**: entender una entrada de voz, audio, imagen o archivo
  (transcribir, leer), instalando lo que haga falta para lograrlo.
- **`install-skill`**: instalar una skill desde una URL, un gist, un repositorio, u
  otro Pepe.
- **`create-watch`**: armar un watch duradero del tipo "revisa X y avísame cuando
  pase".

## Escribe las tuyas propias

Las skills del usuario viven en `~/.pepe/skills/*.md`. Una skill propia reemplaza a la
integrada del mismo nombre, así que si escribes tu propio `handle-media.md`, ese
sustituye por completo al que trae Pepe. La primera línea no vacía funciona como
resumen; todo lo que sigue es el procedimiento en sí, en Markdown corriente, redactado
para que el agente lo lea y lo ejecute.

```bash
~/.pepe/skills/publicar-release.md
```

No hay ningún paso de registro ni necesitas reiniciar nada. Con solo dejar el archivo
ahí, la skill aparece en la lista del agente desde su próximo mensaje.

### Deja que el propio agente la escriba

Un agente puede redactar sus propias skills. Pídele que recuerde cómo hacer algo, como
skill, y, guiado por `skill-creator`, escribirá un nuevo `skills/<nombre>.md` que aparece
de inmediato en su propia lista.

> Tú: eso funcionó. recuerda como skill la manera de publicar una release
>
> Agente: guardé skills/publicar-release.md. La voy a seguir la próxima vez que pidas una release.

Esto es justamente lo que le da permanencia al conocimiento de un agente: un
procedimiento que resolvió una vez queda por escrito, en lugar de tener que
redescubrirlo en cada sesión nueva.

### Aprender sin que nadie se lo pida

En medio de la tarea que de verdad querías resolver, a nadie se le ocurre pedir una skill,
así que casi ningún procedimiento termina por escrito. El flag `skill_learning`,
desactivado por defecto, cierra ese hueco por el otro lado: Pepe mira lo que el turno hizo
realmente y, en los turnos que lo merecen, es el propio agente quien saca el tema.

* **Un procedimiento que vale la pena guardar.** La tarea llevó al menos cuatro llamadas a
  herramientas con éxito, repartidas en al menos dos herramientas distintas, y no se
  consultó ninguna skill existente. El agente puede cerrar su respuesta con una frase
  ofreciéndose a guardar lo que acaba de resolver.
* **Una skill que resultó estar equivocada.** El agente leyó una skill y algo después de
  ella falló. Sus instrucciones llevaron a un sitio que no funciona, así que el agente
  puede ofrecerse a corregirla con lo que le enseñó el fallo: una edición a la skill que ya
  existe, nunca una segunda con otro nombre.

Ofrecer es todo lo que hace. Nada se escribe ni se cambia antes de tu sí, y una consulta
rápida, un bucle de reintentos sobre una sola herramienta o una tarea que ya tenía skill
pasan en silencio.

```bash
pepe agent add ops --skill-learning ...
```

Actívalo en un agente cuyo conocimiento deba ir acumulándose y déjalo apagado cuando la
biblioteca de skills se cura a mano. El mismo interruptor está en el editor de agentes del
panel, y un agente con la herramienta `manage_agent` puede activar `skill_learning` en
otro.

### Ordena su propio desorden

Un agente que escribe sus propias skills termina acumulando un montón que nadie vuelve a
ordenar. Eso es lo que hace el curador, con horario propio, y solo sobre skills que un
agente escribió por su cuenta: una skill que escribiste a mano, instalaste o fijaste
nunca se toca, sea cual sea su estado.

Activado por defecto, hace dos pasadas:

- **Una pasada determinista, sin modelo de por medio.** Una skill escrita por un agente
  va pasando por `active` &rarr; `stale` &rarr; `archived` solo según cuánto tiempo lleve
  sin usarse (queda `stale` a los 14 días, se archiva a los 30, ambos configurables). Si
  se vuelve a usar mientras está `stale`, vuelve a `active`. Archivar mueve la skill a
  `.archive/`: nada se borra, y `pepe skill restore` la trae de vuelta.
- **Una pasada opcional con modelo** (`consolidate`, apagada por defecto porque cuesta
  una corrida): fusiona skills parecidas y demasiado acotadas en otras más amplias, por
  el mismo camino revisado y escaneado que usa cualquier edición vía `manage_skill`.

Corre como máximo una vez por semana, y solo cuando no pasó nada en ninguna conversación
durante unas horas: nunca a mitad de trabajo. Antes de cambiar nada, saca una instantánea
de toda la biblioteca de skills, así que una corrida siempre se puede deshacer:

```bash
pepe skill curator status                  # última corrida, próxima, conteos
pepe skill curator run --dry-run           # ver qué haría, sin cambiar nada
pepe skill curator run --consolidate       # además fusiona skills parecidas, solo esta vez
pepe skill curator pause                   # evita que arranque otra corrida por su cuenta
pepe skill curator backup                  # saca una instantánea a mano
pepe skill curator rollback [ID]           # restaura la última instantánea (o una en particular)
pepe skill curator settings                # stale_after_days, archive_after_days, etc.
pepe skill curator set archive_after_days 45
```

Una sola corrida nunca archiva más de la mitad de la biblioteca (o 20 skills, lo que sea
mayor) a menos que agregues `--force`: una protección contra un umbral mal configurado, o
un montón de skills quedando inactivas todas juntas, que tumbaría la biblioteca antes de
que alguien lo note. También deja de lado cualquier skill editada a mano fuera de
`manage_skill`, ya que esa edición nunca pasó por nada en lo que el curador confíe.
Apágalo del todo con `pepe skill curator set enabled false`. Por ahora es solo por CLI:
todavía no hay control desde el panel ni por chat.

### Empaquetar una skill junto con scripts

Una skill también puede llegar como un pequeño paquete en vez de un solo archivo: una
carpeta `<nombre>/` con `SKILL.md` como documento de entrada (se lee exactamente igual
que un `<nombre>.md` suelto) más lo que necesite además, casi siempre una carpeta
`scripts/`.

```bash
~/.pepe/skills/publicar-release/
  SKILL.md
  scripts/etiquetar-y-publicar.sh
```

Los archivos del paquete nunca se copian a otro lado: el agente los alcanza justo donde
están, del mismo modo en que ya accede al workspace compartido o a un plugin instalado,
pasándole a `run_script` (o a `read_file`) una ruta con la forma
`skills/<nombre>/scripts/<archivo>`. Si las propias instrucciones de `SKILL.md` apuntan a
esa ruta, el script corre exactamente como venía empaquetado, en lugar de que el agente
lo reescriba desde cero cada vez que alguien lo pide por primera vez en una sesión.

Una skill instalada mediante `manage_skill` o `mix pepe skill install` (más abajo) trae
consigo todo el paquete de forma automática cuando la fuente lo incluye: que exista un
`SKILL.md` en la raíz de lo instalado es justamente lo que la marca como paquete;
cualquier cosa que no lo tenga se sigue instalando como un `<nombre>.md` suelto, igual
que siempre. Cada archivo del paquete pasa por el escaneo de seguridad antes de
instalarse, no solo el documento principal: `SKILL.md` recibe el escaneo habitual contra
inyección de prompt, y cada script empaquetado recibe el mismo escaneo profundo que se le
aplica al código de un plugin.

### Un formato que otras herramientas comparten

Muchas herramientas de agentes publican hoy sus skills con la misma forma que ya usa
Pepe: una carpeta con un `SKILL.md` adentro. Sus archivos abren con un bloque YAML entre
`---` que trae al menos `name` y `description`, y esa `description` es el resumen. Pepe
lee esa cabecera, así que una skill escrita para cualquiera de esas herramientas
funciona aquí tal como está, sin nada que convertir.

```markdown
---
name: read-pdf
description: Extrae texto y tablas de PDFs. Úsala cuando el usuario mande un PDF.
---

Ejecuta `scripts/extract.py` con la ruta.
```

La cabecera es opcional y nada cambia en las skills que ya tienes: sin ella, el resumen
sigue siendo la primera línea no vacía. Ponla cuando la skill esté pensada para
circular, porque una skill tuya que la lleve queda igual de legible para todas las demás
herramientas que hablan ese formato. Las claves más allá de `name` y `description`
(`license`, `compatibility`, `metadata`) quedan guardadas en el archivo y no se tocan.
El formato completo está documentado en
[agentskills.io](https://agentskills.io/specification).

Dos piezas más cierran el círculo con ese formato:

```bash
pepe skill validate PATH|NOMBRE
```

revisa una skill contra lo que exige de verdad la especificación (la forma y el largo de
`name`, el largo de `description`, los tipos de `license`/`compatibility`/`metadata`, que
`SKILL.md` abra con una cabecera que se pueda parsear) y reporta aparte lo que solo
tropieza con alguna convención propia de Pepe, meramente indicativa. Lo que falla la
especificación no va a viajar a otra herramienta; lo que solo falla las convenciones de
Pepe sigue funcionando aquí igual. El mismo reporte corre automáticamente en cada
instalación y aparece en el panel.

Una skill también puede declarar lo que necesita para correr de verdad: variables de
entorno (`required_environment_variables`, o las formas
`setup.collect_secrets`/`prerequisites.env_vars` que usan otras herramientas) y comandos
(`required_commands`). Pepe muestra lo que falta en el índice de skills, en `pepe skill
list`, y en el momento en que se abre la skill, en lugar de que el agente se entere recién
cuando falla el primer comando a mitad de la tarea. Un requisito faltante nunca esconde
la skill: las instrucciones siguen valiendo la pena leerse, y capaz estás a punto de
definir esa variable.

Una skill instalada también se convierte en su propio comando de barra en cualquier
superficie que los tenga (Telegram, la consola, el chat del panel, un editor vía ACP):
una skill llamada `weather` responde tanto a `/weather` como a `/skill weather`, y
aparece en el menú "/". Ejecutarla sigue siendo un turno normal, leído a través de la
herramienta `skill`, nunca texto pegado dentro de lo que escribiste, así que aplica la
misma marca de confianza que en cualquier otro lugar donde se lee una skill, y solo se
ofrece a quien de verdad puede verla: mira la
[referencia de comandos de Telegram](../telegram/) para entender esa verificación.

### Instalar una que viene de otro lado

Hay dos caminos, según de dónde venga. Un agente con la herramienta `manage_skill` la usa
para todo lo que el marketplace pueda resolver: un nombre dentro del registro incluido o
en un tap, o una referencia de [PepeHub](https://hub.pepe-agent.com) (`@handle/nombre`, o
directamente la URL de su página). Es la misma instalación consciente del registro que
hace `mix pepe skill install`, y registra confianza y procedencia de la misma manera.
Cuando la fuente no tiene ninguna entrada en ningún registro (una URL suelta, un gist, un
repositorio aislado), la skill `install-skill` le enseña al agente a traerla a mano. En
cualquiera de los dos casos, el texto de una skill externa se trata como entrada no
confiable: el agente lo revisa con la herramienta `scan_skill` antes de escribirlo en
disco. Ese escaneo detecta inyección de prompt, exfiltración de secretos, comandos
destructivos, mecanismos de persistencia y ofuscación. Es una segunda verificación, no
un sustituto de leer el contenido, y nunca instala nada por sí mismo.

## Instalar desde un marketplace

`manage_skill`, ya mencionada arriba, es la vía conversacional para todo lo que los
registros o PepeHub puedan resolver. `mix pepe skill` es la vía del operador hacia esos
mismos registros, con la misma lógica de búsqueda y actualización:

```bash
pepe skill search release            # busca en cada tap más el registro incluido
pepe skill install cut-a-release     # instala por nombre
pepe skill install @jhonathas/google-workspace   # o una referencia de PepeHub (ver abajo)
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # o directamente
pepe skill install read-pdf --source https://github.com/some-org/skills          # una skill dentro de una colección
pepe skill update cut-a-release      # la vuelve a traer desde la fuente exacta con la que se instaló
pepe skill tap add https://github.com/tu-equipo/pepe-skills   # agrega un registro más allá del incluido
```

Un nombre con la forma `@handle/nombre` (o la propia URL de la página del paquete,
copiada directamente de [PepeHub](https://hub.pepe-agent.com)) se resuelve contra PepeHub
en sí, el registro de plugins y skills de Pepe, en lugar del registro incluido o de un
tap. Se comprueba primero, ya que ninguna entrada del registro incluido ni de un tap usa
esa forma. Queda instalada bajo el slug simple del paquete (`google-workspace`, no
`@jhonathas/google-workspace`), el mismo nombre que usan el resto de los comandos de
skill y la herramienta `skill`. Si apuntas `skill install` a un nombre que en realidad
corresponde a un plugin en PepeHub y no a una skill, falla con un mensaje claro que te
indica usar `plugin install` en su lugar.

Una fuente puede guardar una colección entera de skills una al lado de la otra, cada una
en su propia carpeta, que es como se publica la mayoría de las colecciones públicas.
Instalar por nombre elige la carpeta con ese nombre, así que `pepe skill install read-pdf
--source <repo>` trae esa skill y sus archivos, y no la primera que el repositorio liste.

Toda instalación pasa por el mismo escaneo de seguridad estático que usan `manage_skill`
e `install-skill`; un veredicto peligroso se rechaza salvo que agregues `--force`. La
confianza queda marcada como `"official"` para el registro incluido en el propio
repositorio (curado por quienes mantienen Pepe) y para cualquier paquete de PepeHub que
el propio PepeHub haya marcado manualmente como oficial. Todo lo que resuelvas a través
de un tap agregado por ti, un paquete de PepeHub sin esa marca, o algo instalado con
`--source`, queda como `"community"`: cuando un agente lo lee con la herramienta
`skill`, su contenido llega envuelto en el mismo marcador de contenido no confiable que
lleva una página web obtenida por la red, hasta que tú mismo la hayas revisado.

`update` queda fijo a la fuente exacta desde la que se instaló una skill. Si el registro
de un tap apunta luego ese mismo nombre a una fuente *distinta*, `update` se niega en vez
de seguirla en silencio. Una skill con el mismo nombre proveniente de otro lado solo
puede reemplazar a una ya instalada mediante un `install --force` explícito, nunca
mediante una actualización de rutina.

## Skills, plugins y scripts

Estos tres puntos de extensión se combinan entre sí, y esa combinación es justamente lo
que permite pedirle a un agente, en lenguaje natural, algo que todavía no sabe hacer.

Junto con [plugins](../plugins/) y `enable_tool`, puedes pedirle por chat al agente que
instale una herramienta capaz de hacer X. El agente lee la skill `install-tool`, escribe
el plugin en `plugins/<nombre>.exs`, activa la herramienta sobre sí mismo, y empieza a
usarla, todo sin necesidad de reiniciar nada.

Para un trabajo complejo o de varios pasos, el agente no se pone a resolverlo a mano
paso por paso. La herramienta `run_script` le permite escribir un programa corto (en
Python, Node, Ruby, Bash o Elixir, este último siempre disponible) y correrlo,
recibiendo de vuelta la salida estándar, los errores y el código de salida para poder
ir ajustando según lo que falle. Los scripts que vale la pena conservar quedan guardados
bajo `scripts/`, listos para volver a correrse más adelante pasándole a `run_script` una
referencia `file:`. Cuando el agente descubre *cómo* resolver una tarea recurrente, leer
un PDF o procesar una hoja de cálculo, se escribe a sí mismo una skill en
`skills/<nombre>.md`. La skill `write-a-script` enseña justamente ese ciclo completo.
