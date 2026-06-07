---
title: Segredos
description: As três formas de dar uma credencial ao Pepe, o que cada uma realmente protege e um relato honesto do que nenhuma delas faz.
---

O Pepe precisa de credenciais: a chave de API de um provedor de modelos, o token de um bot, o segredo de assinatura de um webhook. Há três formas de fornecer uma, e elas se somam em vez de se substituírem.

## 1. Uma variável de ambiente (o padrão, inalterado)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

O arquivo de configuração guarda o *nome*, nunca o valor, então um backup vazado ou um commit descuidado não entrega nada. É assim que o Pepe sempre funcionou e nada nisso muda.

## 2. Um cofre

Um valor da configuração pode dizer **onde o segredo mora** em vez de guardá-lo. O Pepe o busca no momento em que precisa dele:

```jsonc
// 1Password
"api_key": "exec:op read op://Trabalho/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

São três exemplos, não três integrações. **O contrato inteiro é: um comando que imprime o segredo na saída padrão.** O Pepe não sabe o que é o 1Password, e não existe uma lista de cofres suportados a que se somar. O chaveiro do macOS (`security find-generic-password -w -s openai`), o `gcloud secrets versions access`, o `pass show`, a CLI do Bitwarden e um script que você escreveu hoje de manhã já funcionam, porque todos imprimem um segredo quando são executados.

Um arquivo também funciona, que é exatamente o que é uma montagem de segredo do Docker ou do Kubernetes:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### O que um cofre te dá

Você **revoga uma chave no cofre** e ela para de funcionar em um minuto, sem ssh, sem editar nada, sem reiniciar. O segredo **não está no ambiente**, então um agente enganado para rodar `env` não encontra nada. E o cofre sabe quem leu o quê, coisa que uma variável de ambiente nunca vai saber.

### Se o seu cofre precisar de uma credencial própria

A maioria precisa: um token de conta de serviço, um endereço, um perfil. Nomeie esses, e só esses:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

O Pepe não faz ideia do que essa variável significa. Ele a passa ao seu resolvedor e nada mais do ambiente vai junto, então um resolvedor que busca um segredo não consegue ler os outros de passagem.

### Os custos honestos

O valor resolvido fica **em cache na memória por 60 segundos**, porque abrir um cofre leva algumas centenas de milissegundos e um Pepe movimentado pagaria esse preço a cada chamada ao modelo. Ou seja, o segredo de fato vive no processo por até um minuto. Isso estreita a janela; não a elimina.

E um cofre trancado ou inalcançável é lido como um segredo **não configurado**, nunca como um segredo errado. O Pepe prefere te dizer que não tem chave a autenticar com metade de uma.

## 3. Nenhuma das duas: o agente não vê nada disso

Use a que usar, **o shell do agente não herda os segredos do Pepe**.

Vale dizer isso com todas as letras, porque o esquema `${ENV_VAR}` convida a uma meia verdade confortável. Ele mantém os segredos fora do *arquivo* de configuração, o que é real. E não fazia nada pelo *agente*, porque o segredo ainda precisava existir em algum lugar para o Pepe usá-lo, e esse lugar era o processo do qual o shell do agente é filho. `echo $OPENAI_API_KEY` devolvia a chave. `env` também, que é uma palavra só ao alcance de uma prompt injection.

Agora um comando que o agente roda recebe o ambiente do Pepe menos as credenciais: cada `${VAR}` para a qual a configuração aponta (lê-la é o que a torna um segredo que o Pepe guarda) e cada variável cujo nome diz que ela é uma (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`). `PATH`, `HOME` e o resto do ambiente comum ficam, porque um agente que não acha o `git` é um agente quebrado, e um agente quebrado tem as travas arrancadas por um humano irritado.

<div class="note"><strong>Isto não é um sandbox e não finge ser.</strong> Um agente que roda shell consegue ler qualquer arquivo que você lê. O que isto fecha é o vazamento mais barato e mais provável, com folga, e faz "a configuração não tem segredos" deixar de ser uma frase que significa menos do que parece.</div>

## Quando a tarefa *é* a credencial

Às vezes o trabalho que você dá ao agente é, ele próprio, credenciado: *"pega o login do Postgres no 1Password e roda a migração."* Você quer pedir isso em linguagem natural e o agente se virar, como ele se vira com todo o resto, sem nenhuma fiação por segredo do seu lado.

Esse é o único caso em que o agente precisa de um segredo no próprio shell: o CLI do cofre (`op`) e o token que o abre. Por isso existe um opt-in deliberado. Nomeie o token do cofre em `secrets.expose_env` e ele sobrevive à raspagem para o shell do agente:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Agora o agente pode rodar `op` sozinho: `op vault list`, `op item get "Prod DB"`, e usar o que encontrar. O **skill `vaults`** embutido ensina o fluxo inteiro, incluindo a regra que importa: preferir **`op run`** e **`op inject`**, que entregam o segredo a um comando ou a um template sem o valor nunca ser impresso, em vez de fazer `op read` dele à mostra. O agente instala o `op` sozinho se ele faltar.

<div class="note"><strong>Isto troca uma fronteira por fluidez, de propósito.</strong> Um token de conta de serviço do 1Password só abre os cofres para os quais você o escopou, então o raio de dano é exatamente esse escopo. O Pepe ainda raspa o valor do próprio token de qualquer saída de ferramenta, então um <code>env</code> à toa ou um erro verboso não vazam o token em si. O que sobra é mais estreito: um segredo que o agente leia com <code>op read</code> em vez de injetar com <code>op run</code> ainda vai pra conversa. O skill empurra pra injeção, e o escopo do token limita o resto. Use um token estreitamente escopado, ou não ligue isto.</div>

## Se um token for colado no chat

Ele está comprometido. Não por causa de onde foi parar, mas por causa de onde já esteve: digitado num chat significa enviado ao provedor do modelo, escrito na conversa e escrito no trace em disco.

O Pepe **grava e te avisa** em vez de recusar a escrita, porque recusar não desvaza nada, só deixa você travado. Revogue, reemita, e ponha o novo numa variável de ambiente ou num cofre. O `pepe doctor` continua avisando até você resolver.
