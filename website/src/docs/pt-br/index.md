---
title: Introdução
description: O Pepe roda agentes de IA na sua própria máquina. Você descreve quem eles são, conecta qualquer modelo compatível com OpenAI, e deixa que façam trabalho de verdade usando ferramentas. Sem servidor de banco de dados, sem dependência de fornecedor.
---

## O que é o Pepe

O Pepe roda **agentes** de IA na sua própria máquina ou servidor. Você descreve um agente uma única vez, com um nome, suas instruções, as ferramentas que ele pode usar e o modelo com que ele pensa, e a partir daí o Pepe cuida do resto: assim que um pedido chega, o agente trabalha em etapas, usando as ferramentas disponíveis, até chegar numa resposta de verdade.

Esses agentes existem para durar: conversas, canais, tarefas em segundo plano, não pedidos avulsos que acabam ali. O Pepe é escrito em Elixir/OTP, uma tecnologia feita justamente para esse tipo de carga, e por isso um servidor modesto dá conta de manter uma equipe inteira de agentes rodando lado a lado sem pesar muito em memória ou CPU.

Esse loop interno é o centro de tudo. Uma chamada de chat comum só devolve texto; um agente vai além, consegue de fato fazer coisas: ler um arquivo, rodar um comando, pesquisar na web, chamar a sua API, e só então raciocinar sobre o que encontrou antes de seguir em frente. O Pepe entrega esse loop pronto, como runtime, em vez de deixar você montando isso na mão a cada projeto novo.

```bash
pepe run "leia o package.json e diga quais dependências estão desatualizadas"
```

Você define o comportamento uma única vez, e o mesmo agente fica acessível de quatro jeitos diferentes: pelo terminal, por uma API HTTP compatível com OpenAI, por WebSocket com streaming, e por canais de mensagem como Telegram e WhatsApp. Tem também um painel web para navegar e conversar direto do navegador. A ideia é encontrar cada caso de uso onde ele já acontece, sem precisar recriar um agente do zero para cada canal.

## O loop de chamada de ferramentas

Este é o ciclo que o Pepe roda a cada turno da conversa:

1. Envia a conversa inteira, junto das definições de ferramentas do agente, para o modelo.
2. Se o modelo devolver chamadas de ferramentas, executa cada uma delas e recolhe a saída.
3. Anexa a mensagem do assistente e os resultados das ferramentas de volta na conversa.
4. Volta para o passo 1, e só para quando o modelo devolve uma resposta final, ou quando o agente bate no limite de segurança do `max_iterations`.

Ao longo desse ciclo, o Pepe vai anunciando cada passo, então qualquer superfície consegue mostrar o progresso em tempo real: a resposta enquanto chega em streaming (`assistant_delta`), cada chamada de ferramenta e o resultado dela (`tool_call`, `tool_result`), a resposta final (`done`), e também os erros (`error`).

Ferramentas arriscadas, qualquer uma que rode um comando ou escreva num arquivo, podem ser configuradas para pedir a sua confirmação antes de agir. Se você recusar, a ferramenta simplesmente não roda: o modelo recebe de volta um aviso curto de "negado" (e um evento `tool_denied` é disparado), então o agente nunca chega a agir na sua máquina sem o seu consentimento.

<div class="note"><strong>Ferramentas nativas.</strong> Todo agente pode receber ferramentas como <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code> e <code>web_search</code>. Você escolhe quais delas cada agente vai ter no momento em que o cria, então um bot de suporte e um agente de programação podem acabar com poderes bem diferentes entre si.</div>

## As cinco superfícies

Você monta um agente uma única vez, e o Pepe se encarrega de expô-lo pela superfície que fizer mais sentido para cada tarefa. Já a configuração e o gerenciamento em si acontecem de três formas: pela CLI `pepe`, pelo painel web, ou por conversa mesmo, falando em linguagem natural com um agente que tenha a ferramenta de gerenciamento certa.

### CLI

O comando `pepe` é como você configura tudo e roda agentes direto do terminal. Uma execução avulsa transmite a resposta direto para a saída padrão, enquanto `pepe chat` abre uma sessão interativa que guarda o histórico da conversa.

```bash
pepe run assistant "resuma o git log da última semana"
pepe chat assistant
```

### Painel web

Suba o servidor e abra o painel no navegador para conversar com um agente, revisitar sessões antigas, e gerenciar agentes, conexões de modelo, canais, tarefas agendadas, uso e traces numa interface de apontar e clicar. No localhost ele já vem aberto por padrão; ao expor para fora, dá para protegê-lo atrás de uma senha de operador.

```bash
pepe serve --port 4000
# depois abra http://localhost:4000
```

### API HTTP compatível com OpenAI

Suba o servidor e o Pepe passa a falar o protocolo Chat Completions da OpenAI, então qualquer SDK da OpenAI, o LangChain, ou até um `curl` simples conseguem conversar com ele sem precisar de nenhum adaptador. Ele expõe `POST /v1/chat/completions` e `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "quais arquivos existem neste projeto?"}]
  }'
```

Basta apontar um cliente OpenAI já existente para `http://localhost:4000/v1`, e o nome do modelo vira o nome do seu agente. Detalhes de streaming, eventos de ferramenta e autenticação estão em [na página da API HTTP](../api/).

### WebSocket

Para conversas ao vivo, token a token, dentro de um app web ou mobile, conecte por WebSocket e assine o tópico do seu agente (`agent:<name>`). O texto do assistente chega conforme é gerado, junto com eventos para cada chamada de ferramenta e o respectivo resultado. Tem mais detalhes, e um exemplo de cliente, na [página da API](../api/).

### Canais de mensagem

Ponha o mesmo agente na frente de usuários reais, nas plataformas que eles já usam no dia a dia. O Pepe traz gateways prontos para Telegram, WhatsApp, Slack, Discord, Microsoft Teams e Google Chat, além de um webhook de entrada genérico para qualquer outra coisa que apareça. Cada canal fica vinculado a um agente e mantém sua própria memória de conversa por usuário. Veja mais na [página de canais](../channels/).

## Definindo um agente

Um agente não é nada além de um nome, um prompt de sistema, uma lista de ferramentas e um modelo. Você cria um pela CLI assim:

```bash
pepe agent add assistant \
  --prompt "Você é o Pepe, um agente de programação prestativo." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

Também dá para fazer isso no painel web, na página **Agents**, que já traz um formulário pronto para a persona, o modelo e a escolha de ferramentas.

### Fazendo isso por conversa

Um agente que tenha a ferramenta `manage_agent` consegue criar e ajustar outros agentes direto numa conversa. Basta mandar uma mensagem simples:

> Você: Crie um novo agente chamado "researcher" cujo trabalho é vasculhar a documentação e resumir descobertas, e dê a ele web_search e fetch_url.

O agente usa o `manage_agent` para dar `create` no novo agente, definir a persona dele e adicionar cada ferramenta pedida. O `manage_agent` vem deliberadamente protegido: o agente só pode mexer nos agentes que estão na sua própria lista de permitidos, é instruído a confirmar as mudanças com você antes de aplicar, e, por ser uma ferramenta arriscada, cada chamada ainda passa pela barreira de permissão antes de escrever qualquer coisa. Você vê a mudança proposta e só então decide se aprova.

## Conectando um modelo

O Pepe nunca vem com um modelo ou uma chave embutidos. Você mesmo aponta para o provedor compatível com OpenAI que preferir, através de uma conexão de modelo:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

A página **Models** do painel faz a mesma coisa por um formulário, e ainda testa a conexão antes de você salvar. Repare no `${OPENROUTER_API_KEY}`: segredos ficam guardados como referências a variáveis de ambiente, expandidas só na hora da leitura, então nenhuma das suas chaves acaba gravada em texto puro no disco.

## Adicionando um canal

Vincule um agente a um canal de mensagem para que as pessoas consigam falar com ele onde já estão. No painel, a página **Channels** guia você por toda a conexão de um bot, incluindo a escolha de qual agente ele vai conversar. Depois disso, o canal passa a manter uma memória de conversa separada para cada usuário.

### Fazendo isso por conversa

Um agente que tenha a ferramenta `manage_channel` consegue subir um bot do Telegram sozinho, a partir de uma conversa:

> Você: Adicione um bot do Telegram chamado "support-bot" que fala com o agente de suporte. O token está na variável de ambiente SUPPORT_BOT_TOKEN.

O agente usa `manage_channel` para adicionar esse bot e vinculá-lo ao agente indicado. Essa capacidade também vem deliberadamente protegida: ela só mexe em bots nomeados (nunca no padrão protegido), é instruída a confirmar os detalhes com você antes, e, por ser uma ferramenta arriscada, a chamada passa pela barreira de permissão do mesmo jeito. O mais importante aqui é que você fornece apenas o **nome** de uma variável de ambiente que guarda o token, nunca o token em si, então o segredo nunca chega a passar pelo chat nem pelo modelo. Assim que a mudança é aprovada, o bot entra no ar direto, sem precisar reiniciar nada.

## Decisões de projeto que mantêm tudo simples

### Self-hosted, suas chaves, seus dados

O Pepe nunca embute um modelo ou uma chave de API dentro de si. Você roda tudo na sua própria máquina ou servidor, e aponta para o provedor que quiser. Nada de uma conversa sai da sua infraestrutura, a não ser as chamadas que você mesmo configurou até o endpoint do modelo escolhido.

### Agnóstico quanto ao modelo

Como todo provedor é alcançado pelo mesmo protocolo Chat Completions da OpenAI, trocar de modelo vira uma simples mudança de configuração, não uma mudança de código. OpenAI, OpenRouter, Together, Groq, DeepSeek, Mistral, e servidores locais como Ollama, LM Studio e vLLM, todos funcionam do mesmo jeito. Uma conexão de modelo ainda pode listar modelos de fallback, então uma falha passageira (um limite de taxa, um erro de servidor, uma oscilação de rede) num provedor passa despercebida para o próximo, enquanto uma chave inválida ou uma requisição malformada falha na hora, em vez de ficar tentando de novo à toa.

### Sem servidor de banco de dados

Toda a configuração (conexões de modelo, agentes, canais, agendamentos) mora num único arquivo JSON em `~/.pepe/config.json`, fácil de ler, editar e colocar em backup. Não tem nada a mais para instalar junto com o Pepe, e nada para migrar depois. Segredos são gravados como referências `${ENV_VAR}` e só se expandem na leitura, então suas chaves nunca voltam para o disco em texto puro.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-5-chat"
    }
  }
}
```

### Conversas isoladas entre si

Cada conversa roda de forma independente das demais. Se uma delas quebrar, as outras nem percebem: um turno ruim não consegue derrubar seus outros agentes, nem as outras conversas em andamento.

### Multiprojeto quando você precisar

O trabalho pode ficar limitado a um **projeto**, isolando agentes, canais, modelos e uso por cliente ou por time. Se você nunca optar por isso, tudo continua vivendo no **projeto padrão**, para onde todo comando recorre por conta própria, e você pode simplesmente ignorar a existência de projetos.

## Para onde ir a partir daqui

- [Início rápido](../quickstart/). Instale o Pepe, conecte um modelo, e rode seu primeiro agente em poucos minutos.
- [Agentes e ferramentas](../agents/). Do que um agente é feito, e como ele decide quando usar cada ferramenta.
- [API HTTP](../api/). Comande o Pepe a partir de qualquer cliente compatível com OpenAI, tanto no modo requisição/resposta quanto em streaming.
- [Canais](../channels/). Coloque um agente no Telegram, no WhatsApp, no Slack, e por aí vai.
- [Tarefas agendadas](../scheduled/). Rode agentes numa agenda recorrente.
- [Segurança e permissões](../security/). A barreira de permissão, o sandbox, e como manter um agente dentro de limites seguros.
