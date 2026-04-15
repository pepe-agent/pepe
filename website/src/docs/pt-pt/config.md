---
title: Configuração
description: Entende onde o Pepe guarda configuração, segredos e estado de execução.
---

## Os segredos ficam como referências

A configuração vive num ficheiro JSON simples em `~/.pepe/config.json`. Não há base de dados. Para manter as credenciais fora desse ficheiro, escreva-as como referências `${ENV_VAR}`. O Pepe interpola-as em relação ao ambiente no momento da leitura e nunca persiste o valor expandido.

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

Em tempo de execução a chave real é lida do ambiente. Em disco o ficheiro só contém o marcador. O mesmo mecanismo funciona para os tokens de gateway, as definições de plugins e a palavra-passe do painel, por isso pode versionar ou partilhar uma configuração sem divulgar nada. Exporte as variáveis antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Um marcador de cadeia inteira que se resolve em nada (a variável não está definida) é tratado como "não definido" em vez de uma cadeia vazia, por isso um segredo em falta surge como um claro "não configurado" em vez de um branco silencioso.

### Faça pela conversa

Um agente ao qual sejam concedidas as ferramentas de leitura apenas `config_get` e `doctor` consegue relatar a sua configuração e apanhar um segredo em falta numa conversa normal. Ambas são de leitura apenas, por isso nunca acionam a barreira de permissão.

> Utilizador: Esta tudo configurado corretamente?
>
> Agente: (executa `doctor`) Encontrei um problema: a ligação de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, mas essa variável não está definida no ambiente. Exporte-a antes de servir.

A ferramenta `doctor` faz uma verificação de saúde de toda a configuração e sinaliza segredos `${ENV}` por definir, agentes a apontar para modelos em falta, agendamentos inválidos e ligações inalcançáveis. Passe `live: true` para também sondar a rede.

<div class="note"><strong>As definições sensíveis à segurança não são editáveis pela ferramenta geral de configuração.</strong> A ferramenta protegida `config_set` fecha por predefinição: só mexe numa lista de permissões curta (o modelo e o agente predefinidos, o idioma, o fuso horário e algumas opções do Telegram). Os segredos, as listas de ferramentas permitidas, os tokens de bot, o invólucro do ambiente isolado e a palavra-passe do painel ficam de propósito fora dessa lista, pelo que o `config_set` não os consegue alterar. É o utilizador que os define, através da CLI ou do painel. Os tokens da API são a única coisa que um agente consegue gerar pela conversa, mas apenas através da ferramenta separada e protegida por permissões `manage_token`, nunca através do `config_set`.</div>
