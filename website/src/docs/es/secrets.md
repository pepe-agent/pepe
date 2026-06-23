---
title: Secretos
description: Las tres formas de darle una credencial a Pepe, lo que cada una protege de verdad y un relato honesto de lo que ninguna de ellas hace.
---

Pepe necesita credenciales: la clave de API de un proveedor de modelos, el token de un bot, el secreto de firma de un webhook. Hay tres formas de darle una, y se suman en vez de sustituirse.

## 1. Una variable de entorno (lo predeterminado, sin cambios)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

El archivo de configuración guarda el *nombre*, nunca el valor, así que una copia de seguridad filtrada o un commit descuidado no revelan nada. Así ha funcionado Pepe siempre y nada de esto cambia.

## 2. Una bóveda

Un valor de la configuración puede decir **dónde vive el secreto** en lugar de contenerlo. Pepe lo busca en el momento en que lo necesita:

```jsonc
// 1Password
"api_key": "exec:op read op://Trabajo/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

Son tres ejemplos, no tres integraciones. **El contrato entero es: un comando que imprime el secreto en la salida estándar.** Pepe no sabe qué es 1Password, y no hay una lista de bóvedas soportadas a la que añadirse. El llavero de macOS (`security find-generic-password -w -s openai`), `gcloud secrets versions access`, `pass show`, la CLI de Bitwarden y un script que escribiste esta mañana ya funcionan hoy, porque todos imprimen un secreto cuando los ejecutas.

Un archivo también sirve, que es exactamente lo que es un montaje de secreto de Docker o de Kubernetes:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### Lo que te da una bóveda

**Revocas una clave en la bóveda** y deja de funcionar en un minuto, sin ssh, sin editar nada, sin reiniciar. El secreto **no está en el entorno**, así que un agente engañado para ejecutar `env` no encuentra nada. Y la bóveda sabe quién leyó qué, cosa que una variable de entorno nunca sabrá.

### Si tu bóveda necesita una credencial propia

La mayoría la necesita: un token de cuenta de servicio, una dirección, un perfil. Nombra esas, y solo esas:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Pepe no tiene ni idea de lo que significa esa variable. Se la pasa a tu resolvedor y nada más del entorno va con ella, así que un resolvedor que va a buscar un secreto no puede leer los demás de paso.

### Los costes honestos

El valor resuelto se **cachea en memoria durante 60 segundos**, porque abrir una bóveda cuesta unos cientos de milisegundos y un Pepe con tráfico lo pagaría en cada llamada al modelo. Así que el secreto sí vive en el proceso hasta un minuto. Esto estrecha la ventana; no la elimina.

Y una bóveda bloqueada o inalcanzable se lee como un secreto **no configurado**, nunca como uno equivocado. Pepe prefiere decirte que no tiene clave a autenticarse con media.

## 3. Ninguna de las dos: el agente no ve nada de esto

Uses la que uses, **la shell del agente no hereda los secretos de Pepe**.

Vale la pena decirlo con todas las letras, porque el esquema `${ENV_VAR}` invita a una media verdad cómoda. Mantiene los secretos fuera del *archivo* de configuración, lo cual es real. Y no hacía nada por el *agente*, porque el secreto seguía teniendo que existir en algún sitio para que Pepe lo usara, y ese sitio era el proceso del que la shell del agente es hija. `echo $OPENAI_API_KEY` devolvía la clave. `env` también, que es una sola palabra al alcance de una inyección de prompt.

Ahora un comando que ejecuta el agente recibe el entorno de Pepe menos sus credenciales: cada `${VAR}` a la que apunta la configuración (leerla es lo que la convierte en un secreto que Pepe guarda) y cada variable cuyo nombre dice que lo es (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`). `PATH`, `HOME` y el resto del entorno corriente se quedan, porque un agente que no encuentra `git` es un agente roto, y a un agente roto un humano irritado le arranca las protecciones.

<div class="note"><strong>Esto no es un sandbox ni pretende serlo.</strong> Un agente que puede ejecutar shell puede leer cualquier archivo que tú puedas leer. Lo que cierra es la fuga más barata y más probable, por mucho, y hace que "la configuración no tiene secretos" deje de ser una frase que significa menos de lo que suena.</div>

## Cuando la tarea *es* la credencial

A veces el trabajo que le das al agente está, él mismo, credencializado: *"busca el acceso a Postgres en 1Password y corre la migración."* Quieres pedir eso en lenguaje natural y que el agente se las arregle, igual que se arregla con todo lo demás, sin ningún cableado por secreto de tu parte.

Ese es el único caso en que el agente necesita un secreto en su propia shell: la CLI de la bóveda (`op`) y el token que la abre. Por eso existe una habilitación deliberada. Nombra el token de la bóveda en `secrets.expose_env` y sobrevive al barrido para la shell del agente:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Ahora el agente puede correr `op` por su cuenta: `op vault list`, `op item get "Prod DB"`, y usar lo que encuentre. La **skill `vaults`** incorporada le enseña el flujo entero, incluida la regla que importa: preferir **`op run`** e **`op inject`**, que entregan el secreto a un comando o a una plantilla sin que el valor se imprima nunca, en lugar de hacerle `op read` a la vista. El agente instala `op` por su cuenta si falta. Y si el token está presente pero aún se borra de su shell, el propio agente añade el nombre a `expose_env` mediante la herramienta `config_set`, protegida por la barrera de permisos (una lista de nombres, nunca un valor), en vez de esperar a que tú abras la puerta.

<div class="note"><strong>Esto cambia una frontera por fluidez, a propósito.</strong> Un token de cuenta de servicio de 1Password solo abre las bóvedas a las que lo limitaste, así que el radio de daño es exactamente ese alcance. Pepe además limpia el valor exacto de todo secreto que conoce de la salida de herramienta, y enmascara cualquier cosa con *forma* de credencial que no conoce (<code>PGPASSWORD=…</code>, <code>Bearer …</code>, un JWT), antes de que llegue al modelo o a la traza. Así que un <code>env</code> perdido, un error verboso, e incluso un valor que el agente lea con <code>op read</code> quedan cubiertos. Lo que queda es solo un secreto que Pepe ni conoce ni parece uno; la skill empuja hacia <code>op run</code>, y el alcance del token acota el resto. Usa un token de alcance estrecho, o no actives esto.</div>

## Si un token se pega en el chat

Está comprometido. No por dónde ha acabado, sino por dónde ya ha estado: escrito en un chat significa enviado al proveedor del modelo, escrito en la conversación y escrito en el trace en disco.

Pepe **lo guarda y te avisa** en lugar de rechazar la escritura, porque rechazar no deshace la fuga, solo te deja atascado. Revócalo, reemítelo, y pon el nuevo en una variable de entorno o en una bóveda. `pepe doctor` sigue diciéndolo hasta que lo hagas.
