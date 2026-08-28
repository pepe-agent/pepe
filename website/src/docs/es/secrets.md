---
title: Secretos
description: Las tres formas de darle una credencial a Pepe, qué protege cada una en la práctica, y qué no resuelve ninguna de ellas.
---

Pepe necesita credenciales: la clave de API de un proveedor de modelos, el token de un
bot, el secreto para firmar un webhook. Hay tres maneras de dárselas, y se combinan entre
sí en lugar de competir.

## 1. Una variable de entorno (el método de siempre, intacto)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

En el archivo de configuración solo queda el *nombre*, nunca el valor, así que una copia
de seguridad filtrada o un commit hecho sin cuidado no exponen nada. Pepe funciona así
desde el principio y esto no cambia en absoluto.

## 2. Una bóveda

Un valor de configuración puede indicar **dónde vive el secreto** en lugar de contenerlo
directamente. Pepe va a buscarlo justo cuando lo necesita:

```jsonc
// 1Password
"api_key": "exec:op read op://Trabajo/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

Esos tres son ejemplos, no integraciones separadas. **El contrato completo se reduce a
esto: un comando que imprime el secreto en la salida estándar.** Pepe no tiene idea de qué
es 1Password, ni existe una lista cerrada de bóvedas soportadas a la que sumarse. El
llavero de macOS (`security find-generic-password -w -s openai`), `gcloud secrets
versions access`, `pass show`, la CLI de Bitwarden, o un script que hayas escrito esta
misma mañana, todos funcionan ya, porque todos imprimen un secreto cuando los ejecutas.

Un archivo también sirve, y de hecho es justo lo que hay detrás de un secreto montado en
Docker o Kubernetes:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### Qué ganas con una bóveda

Al **revocar una clave en la bóveda**, deja de funcionar en cuestión de un minuto, sin
necesidad de entrar por ssh, editar nada ni reiniciar. El secreto **no vive en el
entorno**, de modo que un agente al que engañen para correr `env` no encuentra nada ahí.
Y la bóveda queda con un registro de quién leyó qué, algo que una variable de entorno
jamás podría ofrecerte.

### Si tu bóveda necesita su propia credencial

Casi todas la necesitan: un token de cuenta de servicio, una dirección, un perfil.
Nombra exactamente esas, y nada más:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Pepe no sabe qué significa esa variable. Se limita a pasársela al comando que
configuraste, sin arrastrar nada más del entorno, así que un comando que va a buscar un
secreto no puede aprovechar el viaje para leer los demás.

### Los costos, sin maquillar

El valor resuelto queda **en caché durante 60 segundos**, porque abrir una bóveda toma
algunos cientos de milisegundos, y un Pepe con mucho tráfico pagaría ese costo en cada
llamada al modelo si no lo hiciera. Eso significa que el secreto sí queda en memoria del
proceso hasta por un minuto: la ventana se reduce, pero no desaparece.

Y si la bóveda está bloqueada o resulta inalcanzable, eso se interpreta como un secreto
**sin configurar**, jamás como uno incorrecto. Pepe prefiere avisarte que no tiene clave
antes que autenticarse con una mitad de ella.

## 3. Ninguna de las dos cosas: el agente no llega a verlo

Uses la que uses de las dos opciones anteriores, **la shell del agente no hereda los
secretos de Pepe**.

Vale la pena aclararlo bien, porque el esquema `${ENV_VAR}` se presta a una verdad a
medias bastante cómoda. Es cierto que mantiene los secretos fuera del *archivo* de
configuración. Pero durante mucho tiempo no hacía nada respecto al *agente*: el secreto
tenía que existir en algún lugar para que Pepe lo usara, y ese lugar era el proceso del
que la shell del agente terminaba siendo hija. `echo $OPENAI_API_KEY` devolvía la clave
sin problema. Y `env` también, que es apenas una palabra de distancia para cualquier
inyección de prompt.

Hoy, un comando que corre el agente recibe el entorno de Pepe menos sus credenciales: se
descarta cada `${VAR}` que la configuración señala (el mero hecho de leerla es lo que la
convierte en un secreto en manos de Pepe) y cada variable cuyo propio nombre delata que lo
es (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`). `PATH`, `HOME` y el resto del entorno normal
se conservan, porque un agente que no encuentra `git` es un agente inservible, y a un
agente inservible un humano frustrado termina quitándole las protecciones a la fuerza.

<div class="note"><strong>Esto no es un sandbox, y no finge serlo.</strong> Un agente capaz de ejecutar shell puede leer cualquier archivo que tú mismo puedas leer. Lo que este mecanismo elimina es, con mucha diferencia, la fuga más barata y más probable de todas, y evita que "la configuración no tiene secretos" sea una frase que suena más tranquilizadora de lo que en realidad es.</div>

## Cuando la propia tarea exige la credencial

A veces el encargo que le das al agente ya viene con la credencial incluida: *"busca el
acceso a Postgres en 1Password y corre la migración."* Lo natural es pedirlo así, en
lenguaje corriente, y dejar que el agente resuelva el resto por su cuenta, tal como
resuelve cualquier otra cosa, sin que tengas que cablear nada secreto por secreto.

Este es el único caso en que el agente sí necesita un secreto dentro de su propia shell:
la CLI de la bóveda (`op`) y el token que la desbloquea. Por eso existe una vía de opt-in
deliberada. Nombra el token de la bóveda en `secrets.expose_env` y ese sobrevivirá a la
limpieza cuando llegue a la shell del agente:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

A partir de ahí el agente puede correr `op` por sí mismo: `op vault list`, `op item get
"Prod DB"`, y trabajar con lo que encuentre. La **skill `vaults`**, incluida de fábrica, le
enseña el flujo completo, con la regla que de verdad importa: recurrir a **`op run`** y
**`op inject`**, que entregan el secreto a un comando o a una plantilla sin que el valor
llegue nunca a imprimirse, en lugar de sacarlo a la luz con `op read`. Si `op` no está
instalado, el propio agente se encarga de instalarlo. Y si el token está presente pero
sigue quedando fuera de su shell, el agente mismo puede agregar ese nombre a
`expose_env` a través de `config_set` (que solo acepta una lista de nombres, nunca un
valor, y de todos modos pasa por la barrera de permisos), en lugar de quedarse esperando a
que tú abras la puerta.

<div class="note"><strong>Esto cambia una frontera por comodidad, y se hace a propósito.</strong> Un token de cuenta de servicio de 1Password solo destraba las bóvedas a las que lo limitaste, así que el daño posible queda acotado exactamente a ese alcance. Además, Pepe borra el valor exacto de cualquier secreto que ya conoce de toda salida de herramienta, y enmascara cualquier cosa que <em>tenga pinta</em> de credencial aunque no la reconozca (<code>PGPASSWORD=…</code>, <code>Bearer …</code>, un JWT), antes de que llegue al modelo o quede en la traza. Así quedan cubiertos un <code>env</code> suelto, un error demasiado detallado, e incluso un valor que el agente lea con <code>op read</code> por su cuenta. Lo único que queda expuesto es un secreto que ni Pepe conoce ni parece serlo a simple vista; la skill empuja hacia <code>op run</code>, y el alcance del token limita el resto. Usa un token con alcance bien acotado, o directamente no actives esto.</div>

## Si un token termina pegado en el chat

Ya está comprometido. No por dónde quedó guardado, sino por dónde ya pasó: escribirlo en
un chat significa que viajó al proveedor del modelo, que quedó dentro de la conversación,
y que quedó también en la traza guardada en disco.

Pepe **lo guarda y te avisa**, en vez de rechazar el mensaje, porque rechazarlo no
deshace la filtración, solo te deja sin salida. Revócalo, emite uno nuevo, y guarda ese
nuevo token en una variable de entorno o en una bóveda. `pepe doctor` va a seguir
recordándotelo hasta que lo hagas.
