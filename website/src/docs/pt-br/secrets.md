---
title: Segredos
description: As três formas de entregar uma credencial ao Pepe, o que cada uma protege de verdade, e o que nenhuma delas resolve.
---

O Pepe precisa de credenciais: a chave de API de um provedor de modelo, o token de um
bot, o segredo que assina um webhook. Existem três jeitos de fornecer isso, e eles se
somam, não se substituem.

## 1. Variável de ambiente (o padrão de sempre)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

O arquivo de configuração guarda só o *nome* da variável, nunca o valor. Um backup
vazado ou um commit por descuido não entrega nada. Isso é como o Pepe sempre funcionou
e continua funcionando exatamente assim.

## 2. Um cofre

Em vez de guardar o segredo, um valor de configuração pode simplesmente dizer **onde
ele mora**, e o Pepe busca no momento em que precisa:

```jsonc
// 1Password
"api_key": "exec:op read op://Trabalho/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

Esses três exemplos não são três integrações separadas, é sempre o mesmo contrato:
**um comando que imprime o segredo na saída padrão**, ponto final. O Pepe não sabe o
que é 1Password, nem existe uma lista fechada de cofres suportados esperando por mais
um nome. O chaveiro do macOS (`security find-generic-password -w -s openai`), o
`gcloud secrets versions access`, o `pass show`, a CLI do Bitwarden, ou um script que
você escreveu hoje de manhã, todos funcionam hoje mesmo, porque todos têm em comum
imprimir um segredo quando rodados.

Um arquivo também serve, e é basicamente isso que uma montagem de secret do Docker ou
do Kubernetes é:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### O que um cofre te dá de verdade

Revogar uma chave direto no cofre a derruba em até um minuto, sem precisar de ssh,
edição ou reinício de nada. O segredo também **não fica exposto no ambiente**, então
um agente induzido a rodar `env` não acha nada ali. E, ao contrário de uma variável de
ambiente, o cofre sabe registrar quem leu o quê.

### Quando o próprio cofre precisa de uma credencial

Na maioria das vezes precisa: um token de service account, um endereço, um perfil.
Nomeie só o que for estritamente necessário:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

O Pepe não faz ideia do que aquela variável significa: ele só a repassa para o comando
que você configurou, e nada mais do ambiente viaja junto. Assim, um comando que busca
um segredo não consegue, de carona, ler os outros.

### Os custos, sem esconder nada

O valor resolvido fica **em cache na memória por 60 segundos**, porque abrir um cofre
custa algumas centenas de milissegundos, e um Pepe com tráfego alto pagaria esse preço
a cada chamada de modelo se não fosse assim. Na prática, isso significa que o segredo
chega a viver no processo por até um minuto: a janela fica menor, mas não desaparece.

Um cofre trancado ou fora do ar aparece como um segredo **não configurado**, nunca
como um segredo errado. O Pepe prefere admitir que não tem a chave a tentar autenticar
com metade dela.

## 3. Nenhum dos dois: o agente simplesmente não vê nada disso

Seja qual for o método escolhido acima, uma coisa não muda: **o shell do agente não
herda os segredos do Pepe**.

Vale explicar isso com calma, porque o esquema `${ENV_VAR}` costuma sugerir uma
segurança maior do que de fato entrega. Ele tira o segredo do *arquivo* de
configuração, isso é real. Só que, até pouco tempo, isso não protegia em nada o
*agente*: o segredo ainda precisava existir em algum lugar para o Pepe usar, e esse
lugar era justamente o processo do qual o shell do agente nasce como filho. Um
`echo $OPENAI_API_KEY` devolvia a chave direto. Um simples `env` também, e chegar a
esse comando é o trabalho de uma única prompt injection bem colocada.

Hoje, um comando rodado pelo agente recebe o ambiente do Pepe menos as credenciais:
cada `${VAR}` referenciada na configuração (é justamente ler essa variável que a
transforma num segredo do Pepe) e qualquer variável cujo próprio nome já denuncia o
que é (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`). `PATH`, `HOME` e o resto do ambiente
comum continuam lá, porque um agente incapaz de achar o `git` é um agente quebrado, e
um agente quebrado é o tipo de coisa que faz um humano irritado arrancar todas as
travas de proteção sozinho.

<div class="note"><strong>Isso não é um sandbox, e não finge ser um.</strong> Um agente com acesso a shell consegue ler qualquer arquivo que você também consegue ler. O que essa proteção fecha é, de longe, o vazamento mais barato e mais provável de acontecer, e é o que impede a frase "a configuração não guarda segredos" de significar menos do que parece.</div>

## Quando a própria tarefa exige credencial

Às vezes o trabalho que você passa ao agente já nasce credenciado: *"acha o login do
Postgres no 1Password e roda a migração."* Nesse caso, o ideal é simplesmente pedir em
linguagem natural e deixar o agente resolver sozinho, do mesmo jeito que resolve tudo
o mais, sem você precisar cabear cada segredo à mão.

Esse é o único caso em que o agente realmente precisa de um segredo no próprio shell:
a CLI do cofre (`op`) e o token que a destrava. Por isso existe um opt-in deliberado.
Coloque o nome do token do cofre em `secrets.expose_env` e ele sobrevive à limpeza,
chegando inteiro ao shell do agente:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

A partir daí o agente roda `op` por conta própria: `op vault list`, `op item get "Prod
DB"`, e usa o que encontrar. A **skill `vaults`**, já embutida, ensina o fluxo
inteiro, com a regra que mais importa: preferir sempre **`op run`** e **`op inject`**,
que entregam o segredo direto a um comando ou a um template sem nunca imprimir o
valor, em vez de simplesmente rodar `op read` e deixar o valor exposto. Se o `op`
estiver faltando, o próprio agente instala. E se o token existir mas ainda estiver
sendo removido do shell dele, o agente pode adicionar o nome ao `expose_env` sozinho,
usando o `config_set` (que aceita só uma lista de nomes, nunca um valor, e ainda passa
pela barreira de permissão), em vez de esperar você abrir essa porta manualmente.

<div class="note"><strong>Aqui se troca uma fronteira por fluidez, de propósito.</strong> Um token de service account do 1Password só abre os cofres para os quais ele foi escopado, então o estrago possível se limita a esse escopo. Além disso, o Pepe continua raspando o valor exato de todo segredo que conhece antes de qualquer saída de ferramenta, e mascara qualquer coisa com <em>cara</em> de credencial mesmo sem reconhecer (<code>PGPASSWORD=…</code>, <code>Bearer …</code>, um JWT), antes que aquilo chegue ao modelo ou ao trace. Um <code>env</code> solto, um erro verboso demais, até um valor que o próprio agente leia via <code>op read</code>: tudo isso é pego. Só escapa um segredo que o Pepe nem conhece nem reconhece visualmente como segredo, e é para isso que a skill empurra o agente ao <code>op run</code>, com o escopo do token limitando o resto. Use um token com escopo bem estreito, ou simplesmente não ative isso.</div>

## Se um token acabar colado no chat

Considere-o comprometido. Não pelo lugar onde ele parou, mas pelos lugares por onde já
passou: digitar num chat significa que ele já foi enviado ao provedor do modelo,
gravado na conversa e gravado no trace em disco.

Por isso o Pepe **salva e te avisa**, em vez de recusar a escrita: recusar não desfaz
o vazamento, só deixa você numa posição pior. O caminho certo é revogar aquele token,
emitir um novo e colocá-lo numa variável de ambiente ou num cofre. O `pepe doctor`
continua alertando sobre isso até você resolver.
