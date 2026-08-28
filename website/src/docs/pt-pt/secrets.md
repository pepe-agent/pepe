---
title: Segredos
description: As três formas de dar uma credencial ao Pepe, o que cada uma protege de facto, e um relato honesto sobre o que nenhuma delas resolve.
---

O Pepe precisa de credenciais: a chave de API de um fornecedor de modelos, o token de
um bot, o segredo que assina um webhook. Há três formas de lhas dar, e elas somam-se
umas às outras em vez de se substituírem.

## 1. Uma variável de ambiente (a predefinição, sem mudanças)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

O ficheiro de configuração guarda o *nome*, nunca o valor, e por isso uma cópia de
segurança que fuja ou um commit descuidado não entregam nada a ninguém. É assim que o
Pepe sempre funcionou, e continua a funcionar exatamente assim.

## 2. Um cofre

Em vez de guardar o segredo, um valor da configuração pode simplesmente dizer **onde
ele vive**, e o Pepe vai buscá-lo no momento em que precisa dele:

```jsonc
// 1Password
"api_key": "exec:op read op://Trabalho/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

Repara que são três exemplos, não três integrações: **o contrato inteiro resume-se a
um comando que imprime o segredo na saída padrão.** O Pepe não sabe o que é o
1Password, nem existe uma lista fechada de cofres suportados à qual só se possa
acrescentar por decreto. O porta-chaves do macOS (`security find-generic-password -w
-s openai`), o `gcloud secrets versions access`, o `pass show`, a CLI do Bitwarden, ou
um script que escreveste hoje de manhã, todos funcionam já, porque todos imprimem um
segredo quando são executados.

Um ficheiro também serve, e é precisamente isso que é uma montagem de segredo do
Docker ou do Kubernetes:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### O que um cofre te dá

**Revogas uma chave no cofre** e ela para de funcionar dentro de um minuto, sem ssh,
sem editar nada, sem reiniciar seja o que for. O segredo **não vive no ambiente**, por
isso um agente enganado para correr `env` não encontra nada ali. E, ao contrário de
uma variável de ambiente, o cofre sabe sempre quem leu o quê.

### Quando o próprio cofre precisa de uma credencial

A maioria precisa mesmo: um token de conta de serviço, um endereço, um perfil. Nomeia
só esses, e nada mais:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

O Pepe não faz a mínima ideia do que essa variável significa; limita-se a passá-la ao
comando que configuraste, e mais nada do resto do ambiente segue junto, por isso um
comando que vai buscar um segredo não consegue, de caminho, ler os outros.

### Os custos, sem esconder nada

O valor resolvido fica **em cache na memória durante 60 segundos**, porque abrir um
cofre custa algumas centenas de milissegundos, e um Pepe com muito movimento estaria a
pagar esse preço em cada chamada ao modelo se não fosse assim. Ou seja: o segredo
chega mesmo a viver no processo por até um minuto. Isto estreita a janela de risco;
não a fecha por completo.

E um cofre trancado ou inacessível é lido como um segredo **não definido**, nunca como
um segredo errado: o Pepe prefere dizer-te que não tem chave nenhuma a tentar
autenticar-se com meia chave.

## 3. Nenhuma das duas: o agente não vê nada disto

Seja qual for a opção que uses, **a shell do agente não herda os segredos do Pepe**.

Vale a pena explicar bem isto, porque o esquema `${ENV_VAR}` convida a uma meia
verdade confortável. É verdade que mantém os segredos fora do *ficheiro* de
configuração. Mas, durante muito tempo, não fazia nada pelo lado do *agente*: o
segredo continuava a ter de existir algures para o Pepe conseguir usá-lo, e esse
algures era o processo de que a shell do agente é filha. Um simples `echo
$OPENAI_API_KEY` devolvia a chave. E `env` também, que é só uma palavra ao alcance de
qualquer prompt injection.

Hoje, um comando que o agente corre recebe o ambiente do Pepe menos as credenciais:
cada `${VAR}` para onde a configuração aponta (é lê-la que faz dela um segredo que o
Pepe guarda) e cada variável cujo nome já denuncia o que é (`GITHUB_TOKEN`,
`AWS_SECRET_ACCESS_KEY`). O `PATH`, o `HOME` e o resto do ambiente comum ficam onde
estavam, porque um agente que não encontra o `git` é um agente avariado, e a um
agente avariado um humano irritado tende a arrancar-lhe as proteções todas.

<div class="note"><strong>Isto não é uma sandbox, e não finge sê-lo.</strong> Um agente capaz de correr shell continua a conseguir ler qualquer ficheiro que tu consigas ler. O que isto fecha é a fuga mais barata e mais provável, com grande margem, e evita que "a configuração não tem segredos nenhuns" seja uma frase que promete mais do que cumpre.</div>

## Quando a própria tarefa exige a credencial

Às vezes o trabalho que pedes ao agente já vem com credencial embutida: *"vai buscar o
login do Postgres ao 1Password e corre a migração."* Aqui queres mesmo poder pedir
isto em linguagem simples e deixar o agente desenrascar-se, tal como já faz com o
resto, sem teres de ligar cada segredo à mão do teu lado.

Esse é o único caso em que o agente precisa mesmo de um segredo na própria shell: a
CLI do cofre (`op`) e o token que a destranca. Por isso existe uma adesão deliberada.
Nomeia o token do cofre em `secrets.expose_env` e ele sobrevive à limpeza, chegando
mesmo à shell do agente:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

A partir daí o agente já consegue correr o `op` sozinho: `op vault list`, `op item get
"Prod DB"`, e usar o que encontrar. A **skill nativa `vaults`** ensina-lhe o fluxo
inteiro, incluindo a regra mais importante: preferir sempre **`op run`** e **`op
inject`**, que entregam o segredo a um comando ou a um modelo de texto sem que o valor
alguma vez apareça a descoberto, em vez de o ler diretamente com `op read`. Se faltar
o `op`, o próprio agente instala-o. E se o token existir mas continuar retirado da sua
shell, é o próprio agente que consegue acrescentar o nome a `expose_env`, através da
ferramenta `config_set` com barreira de permissão (só uma lista de nomes, nunca um
valor), sem ter de esperar que sejas tu a abrir essa porta.

<div class="note"><strong>Isto troca uma fronteira por fluidez, de propósito.</strong> Um token de conta de serviço do 1Password só abre os cofres para os quais o delimitaste, por isso o raio de estrago fica exatamente dentro desse âmbito. Além disso, o Pepe continua a limpar da saída de qualquer ferramenta o valor exato de todo o segredo que conhece, e mascara também qualquer coisa com <em>cara</em> de credencial mesmo sem a reconhecer (<code>PGPASSWORD=…</code>, <code>Bearer …</code>, um JWT), antes de isso chegar ao modelo ou ao trace. Assim, um <code>env</code> corrido por engano, um erro verboso, ou até um valor que o agente leia com <code>op read</code> acabam apanhados. O que sobra é só um segredo que o Pepe não conhece e que não tem cara de segredo; a skill empurra sempre para o <code>op run</code>, e o âmbito do token limita o resto. Usa um token com âmbito bem estreito, ou não ligues nada disto.</div>

## Se um token acabar colado no chat

Está comprometido. Não pelo sítio onde caiu, mas pelo caminho que já percorreu:
escrito num chat significa enviado ao fornecedor do modelo, gravado na conversa e
gravado no trace em disco.

O Pepe **guarda-o e avisa-te**, em vez de recusar a escrita, porque recusar não desfaz
fuga nenhuma, só te deixa preso sem saber o que fazer. Revoga-o, emite outro, e põe o
novo numa variável de ambiente ou num cofre. O `pepe doctor` continua a lembrar-te
disso até resolveres.
