---
title: Segredos
description: As três formas de dar uma credencial ao Pepe, o que cada uma protege de facto e um relato honesto do que nenhuma delas faz.
---

O Pepe precisa de credenciais: a chave de API de um fornecedor de modelos, o token de um bot, o segredo de assinatura de um webhook. Há três formas de lhe dar uma, e elas somam-se em vez de se substituírem.

## 1. Uma variável de ambiente (a predefinição, inalterada)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

O ficheiro de configuração guarda o *nome*, nunca o valor, por isso uma cópia de segurança que fuja ou um commit descuidado não entregam nada. É assim que o Pepe sempre funcionou e nada disto muda.

## 2. Um cofre

Um valor da configuração pode dizer **onde o segredo vive** em vez de o guardar. O Pepe vai buscá-lo no momento em que precisa dele:

```jsonc
// 1Password
"api_key": "exec:op read op://Trabalho/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

São três exemplos, não três integrações. **O contrato inteiro é: um comando que imprime o segredo na saída padrão.** O Pepe não sabe o que é o 1Password, e não existe uma lista de cofres suportados à qual acrescentar. O porta-chaves do macOS (`security find-generic-password -w -s openai`), o `gcloud secrets versions access`, o `pass show`, a CLI do Bitwarden e um script que escreveste esta manhã já funcionam, porque todos imprimem um segredo quando são executados.

Um ficheiro também funciona, que é precisamente o que é uma montagem de segredo do Docker ou do Kubernetes:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### O que um cofre te dá

**Revogas uma chave no cofre** e ela deixa de funcionar dentro de um minuto, sem ssh, sem editar nada, sem reiniciar. O segredo **não está no ambiente**, por isso um agente enganado para executar `env` não encontra nada. E o cofre sabe quem leu o quê, coisa que uma variável de ambiente nunca saberá.

### Se o teu cofre precisar de uma credencial própria

A maioria precisa: um token de conta de serviço, um endereço, um perfil. Nomeia esses, e só esses:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

O Pepe não faz ideia do que essa variável significa. Passa-a ao teu resolvedor e mais nada do ambiente vai com ela, por isso um resolvedor que vai buscar um segredo não consegue ler os outros pelo caminho.

### Os custos honestos

O valor resolvido fica **em cache na memória durante 60 segundos**, porque abrir um cofre demora algumas centenas de milissegundos e um Pepe com movimento pagaria esse preço em cada chamada ao modelo. Ou seja, o segredo vive mesmo no processo até um minuto. Isto estreita a janela; não a elimina.

E um cofre trancado ou inalcançável é lido como um segredo **não configurado**, nunca como um segredo errado. O Pepe prefere dizer-te que não tem chave a autenticar-se com metade de uma.

## 3. Nenhuma das duas: o agente não vê nada disto

Uses o que usares, **a shell do agente não herda os segredos do Pepe**.

Vale a pena dizê-lo com todas as letras, porque o esquema `${ENV_VAR}` convida a uma meia verdade confortável. Mantém os segredos fora do *ficheiro* de configuração, o que é real. E não fazia nada pelo *agente*, porque o segredo continuava a ter de existir algures para o Pepe o usar, e esse algures era o processo de que a shell do agente é filha. `echo $OPENAI_API_KEY` devolvia a chave. `env` também, que é uma única palavra ao alcance de uma prompt injection.

Agora um comando que o agente executa recebe o ambiente do Pepe menos as credenciais: cada `${VAR}` para que a configuração aponta (lê-la é o que faz dela um segredo que o Pepe guarda) e cada variável cujo nome diz que é uma (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`). `PATH`, `HOME` e o resto do ambiente comum ficam, porque um agente que não encontra o `git` é um agente avariado, e a um agente avariado um humano irritado arranca-lhe as protecções.

<div class="note"><strong>Isto não é uma sandbox e não finge sê-lo.</strong> Um agente que executa shell consegue ler qualquer ficheiro que tu consigas ler. O que isto fecha é a fuga mais barata e mais provável, com folga, e faz com que "a configuração não tem segredos" deixe de ser uma frase que significa menos do que parece.</div>

## Quando a tarefa *é* a credencial

Às vezes o trabalho que dás ao agente é, ele próprio, credenciado: *"vai buscar o login do Postgres ao 1Password e corre a migração."* Queres pedir isso em linguagem natural e o agente desenrascar-se, como se desenrasca com tudo o resto, sem nenhuma ligação por segredo do teu lado.

Esse é o único caso em que o agente precisa de um segredo na própria shell: a CLI do cofre (`op`) e o token que o abre. Por isso existe uma adesão deliberada. Nomeia o token do cofre em `secrets.expose_env` e ele sobrevive à limpeza para a shell do agente:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Agora o agente pode correr `op` sozinho: `op vault list`, `op item get "Prod DB"`, e usar o que encontrar. O **skill `vaults`** incorporado ensina-lhe o fluxo inteiro, incluindo a regra que importa: preferir **`op run`** e **`op inject`**, que entregam o segredo a um comando ou a um template sem o valor alguma vez ser impresso, em vez de fazer `op read` dele à vista. O agente instala o `op` sozinho se faltar.

<div class="note"><strong>Isto troca uma fronteira por fluidez, de propósito.</strong> Um token de conta de serviço do 1Password só abre os cofres para os quais o delimitaste, por isso o raio de dano é exatamente esse âmbito. O Pepe ainda limpa o valor do próprio token de qualquer saída de ferramenta, por isso um <code>env</code> à toa ou um erro verboso não deixam fugir o token em si. O que resta é mais estreito: um segredo que o agente leia com <code>op read</code> em vez de injetar com <code>op run</code> ainda vai parar à conversa. O skill encaminha para a injeção, e o âmbito do token limita o resto. Usa um token estreitamente delimitado, ou não ligues isto.</div>

## Se um token for colado no chat

Está comprometido. Não por causa de onde foi parar, mas por causa de onde já esteve: escrito num chat significa enviado ao fornecedor do modelo, escrito na conversa e escrito no trace em disco.

O Pepe **guarda-o e avisa-te** em vez de recusar a escrita, porque recusar não desfaz a fuga, apenas te deixa preso. Revoga-o, reemite-o, e põe o novo numa variável de ambiente ou num cofre. O `pepe doctor` continua a dizê-lo até o resolveres.
