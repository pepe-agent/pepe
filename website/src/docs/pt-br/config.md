---
title: Configuração
description: Entenda onde o Pepe guarda configuração, segredos e estado de execução.
---

## Onde sua configuração vive

Tudo o que você fez acima está agora em `~/.pepe/config.json`: a conexão do modelo,
o agente e quaisquer canais. Sem banco de dados, sem migrações. Para mover uma
configuração para outra máquina, copie esse arquivo e defina as mesmas variáveis de
ambiente para as quais suas referências `${VAR}` apontam.

```bash
pepe config
```

Isso imprime o caminho da configuração e um resumo do que está definido.

## Os segredos ficam como referências

A configuração fica em um arquivo JSON simples em `~/.pepe/config.json`. Não ha banco de dados. Para manter as credenciais fora desse arquivo, escreva-as como referências `${ENV_VAR}`. O Pepe as interpola contra o ambiente no momento da leitura e nunca persiste o valor expandido.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini"
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}" }
}
```

Em tempo de execução a chave real é lida do ambiente. Em disco o arquivo só contém o marcador. O mesmo mecanismo funciona para os tokens de gateway, os ajustes de plugins e a senha do painel, então você pode versionar ou compartilhar uma configuração sem vazar nada. Exporte as variáveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador de string inteira que resolve para nada (a variável não está definida) é tratado como "não definido" em vez de uma string vazia, então um segredo ausente aparece como um claro "não configurado" em vez de um branco silencioso.

### Faça pela conversa

Um agente que recebe as ferramentas somente leitura `config_get` e `doctor` consegue relatar a sua configuração e pegar um segredo ausente numa conversa normal. Ambas são somente leitura, então nunca disparam a barreira de permissão.

> Você: Esta tudo configurado corretamente?
>
> Agente: (roda `doctor`) Encontrei um problema: a conexão de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variável não está definida no ambiente. Exporte-a antes de servir.

A ferramenta `doctor` faz uma verificação de saúde de toda a configuração e sinaliza segredos `${ENV}` não definidos, agentes apontando para modelos ausentes, agendamentos inválidos e conexões inalcançáveis. Passe `live: true` para também sondar a rede.

<div class="note"><strong>Ajustes sensíveis à segurança não são editáveis pela ferramenta geral de configuração.</strong> A ferramenta protegida `config_set` é fechada por padrão: ela só mexe numa lista de permissão curta (o modelo e o agente padrão, o idioma, o fuso horário e algumas poucas opções do Telegram). Segredos, listas de ferramentas permitidas, tokens de bot, o invólucro do ambiente isolado e a senha do painel ficam de propósito fora dessa lista, então o `config_set` não consegue mudá-los. Você define esses por conta própria com a CLI ou o painel. Os tokens da API são a única coisa que um agente consegue gerar pela conversa, mas apenas pela ferramenta separada e protegida por barreira de permissão `manage_token`, nunca pelo `config_set`.</div>
