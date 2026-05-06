---
title: Introdução
description: O Pepe é um runtime de agentes de IA auto-hospedado e agnóstico de modelo. Defina agentes, conecte qualquer modelo compatível com OpenAI e rode um loop real de chamada de ferramentas, sem banco de dados e sem dependência de fornecedor.
---

## O que é o Pepe

O Pepe é um runtime de agentes de IA auto-hospedado, construído em Elixir. Você
define um **agente** (um nome, um prompt de sistema, um conjunto de ferramentas e
uma conexão com um modelo), e o Pepe o executa: envia a conversa para o modelo,
executa qualquer ferramenta que o modelo pedir, devolve os resultados e repete
até o modelo produzir uma resposta final.

Elixir/OTP importa aqui porque agentes são conversas longas, canais e tarefas em
segundo plano, não só uma requisição HTTP. O Pepe consegue manter muitas sessões
supervisionadas com pouco overhead, o que ajuda a hospedar uma equipe de agentes
sem inflar memória nem CPU do servidor.

Esse loop interno é o ponto central de tudo. Uma simples chamada de chat devolve
texto. Um agente pode de fato fazer coisas: ler um arquivo, rodar um comando,
pesquisar na web, chamar sua API, e então raciocinar sobre o que encontrou e
seguir em frente. O Pepe entrega esse loop como um runtime pronto, em vez de algo
que você monta na mão em cada projeto.

```bash
pepe run "leia o package.json e diga quais dependências estão desatualizadas"
```

Você define o comportamento uma vez, e o mesmo agente fica acessível de quatro
formas: pelo terminal, por uma API HTTP compatível com OpenAI, por um WebSocket
com streaming, e por canais de mensagem como Telegram e WhatsApp. Também há um
painel web para navegar e conversar pelo navegador. Atenda cada caso de uso ali
onde ele já vive, sem criar um agente separado para cada canal.

## O loop de chamada de ferramentas

Este é o ciclo que o Pepe roda a cada turno:

1. Envia a conversa, junto com as definições de ferramentas do agente, para o
   modelo.
2. Se o modelo devolver chamadas de ferramentas, executa cada uma e coleta a
   saída.
3. Anexa a mensagem do assistente e os resultados das ferramentas à conversa.
4. Volta ao passo 1. Para quando o modelo devolve uma resposta simples, ou quando
   o agente atinge seu limite de segurança `max_iterations`.

Ao longo do caminho, o runtime emite eventos de ciclo de vida para que qualquer
superfície possa mostrar o progresso em tempo real: fragmentos de texto em
streaming (`assistant_delta`), um turno completo do assistente (`assistant`),
cada chamada de ferramenta (`tool_call`), cada resultado de ferramenta
(`tool_result`), a resposta final (`done`) e os erros (`error`). As superfícies
com streaming mostram os tokens conforme eles chegam.

Ferramentas arriscadas (qualquer uma que rode um comando ou escreva um arquivo)
podem passar por uma barreira de permissão que pede ao usuário para aprovar
antes de a ferramenta rodar. Se o usuário recusar, o runtime emite um evento `tool_denied`
e entrega ao modelo uma breve mensagem de "negado" em vez de rodar a ferramenta,
de modo que um agente nunca age silenciosamente na sua máquina sem o seu
consentimento.

<div class="note"><strong>Ferramentas embutidas.</strong> Cada agente pode receber ferramentas como <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code> e <code>web_search</code>. Você escolhe quais cada agente recebe ao criá-lo, então um bot de suporte e um agente de programação podem ter poderes bem diferentes.</div>

## As cinco superfícies

Você constrói um agente uma vez. O Pepe então o expõe pela superfície que melhor
serve à tarefa. A configuração e o gerenciamento, por sua vez, acontecem de três
maneiras: a CLI `pepe`, o painel web e pela conversa (falando em linguagem natural com
um agente que possui a ferramenta de gerenciamento certa).

### CLI

O comando `pepe` é como você configura as coisas e como roda agentes a partir de
um terminal. Execuções pontuais transmitem a resposta direto para a saída padrão,
e `pepe chat` abre uma sessão interativa que lembra a conversa.

```bash
pepe run assistant "resuma o git log da última semana"
pepe chat assistant
```

### Painel web

Rode o servidor e abra o painel em um navegador para conversar com um agente,
navegar por sessões anteriores e gerenciar agentes, conexões de modelo, canais,
tarefas agendadas, uso e traces por uma interface de apontar e clicar. Em
localhost ele fica aberto por padrão; você pode protegê-lo atrás de uma senha de
operador quando o expuser.

```bash
pepe serve --port 4000
# então abra http://localhost:4000
```

### API HTTP compatível com OpenAI

Suba o servidor e o Pepe fala o protocolo Chat Completions da OpenAI, então
qualquer SDK da OpenAI, LangChain ou um simples `curl` conseguem conversar com ele
sem adaptador. Ele serve `POST /v1/chat/completions` e `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "quais arquivos existem neste projeto?"}]
  }'
```

Aponte um cliente OpenAI existente para `http://localhost:4000/v1` e o nome do
modelo passa a ser o nome do seu agente. Veja [a página da API HTTP](../api/) para
streaming, eventos de ferramentas e autenticação.

### WebSocket

Para conversas ao vivo, token a token, em um app web ou mobile, conecte-se por um
WebSocket e assine o tópico do seu agente (`agent:<name>`). Você recebe o texto do
assistente conforme ele é transmitido, além de eventos para cada chamada e
resultado de ferramenta. Os detalhes e um exemplo de cliente estão na [página da
API](../api/).

### Canais de mensagem

Coloque o mesmo agente na frente de usuários reais nas plataformas que eles já
usam. O Pepe traz gateways para Telegram, WhatsApp, Slack, Discord, Microsoft
Teams e Google Chat, além de um webhook de entrada genérico para qualquer outra
coisa. Cada canal se vincula a um agente e mantém sua própria memória de conversa
por usuário. Veja [a página de canais](../channels/).

## Definindo um agente

Um agente é só um nome, um prompt de sistema, uma lista de ferramentas e um
modelo. Crie um pela CLI:

```bash
pepe agent add assistant \
  --prompt "Você é o Pepe, um agente de programação prestativo." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

Você também pode fazer isso no painel web, na página **Agents**, que inclui um
formulário para a persona, o modelo e a seleção de ferramentas.

### Faça pela conversa

Um agente que possui a ferramenta `manage_agent` pode criar e moldar outros
agentes direto de uma conversa. Mande uma mensagem simples para ele:

> Você: Crie um novo agente chamado "researcher" cujo trabalho é vasculhar a
> documentação e resumir descobertas, e dê a ele web_search e fetch_url.

O agente usa `manage_agent` para `create` o novo agente, definir sua persona e
adicionar cada ferramenta. `manage_agent` é uma capacidade protegida: o agente só
pode mexer nos agentes da própria lista de permitidos, é instruído a confirmar as
mudanças com você primeiro, e por ser uma ferramenta arriscada, cada chamada
ainda passa pela barreira de permissão antes de qualquer coisa ser escrita. Assim
você vê a mudança proposta e a aprova antes que ela tenha efeito.

## Conectando um modelo

O Pepe nunca embute um modelo ou uma chave. Você o aponta para qualquer provedor
compatível com OpenAI por meio de uma conexão de modelo:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

A página **Models** do painel faz o mesmo com um formulário, e pode testar uma
conexão antes de você salvá-la. Repare no `${OPENROUTER_API_KEY}`: segredos são
guardados como referências a variáveis de ambiente e expandidos apenas na leitura,
então suas chaves nunca são escritas de volta no disco em texto puro.

## Adicionando um canal

Vincule um agente a um canal de mensagem para que as pessoas possam falar com ele
onde já estão. No painel, a página **Channels** guia você pela conexão de um bot e
pela escolha de qual agente ele conversa. O canal então mantém uma memória de
conversa separada por usuário.

### Faça pela conversa

Um agente que possui a ferramenta `manage_channel` pode subir um bot do Telegram
a partir de uma conversa:

> Você: Adicione um bot do Telegram chamado "support-bot" que fala com o agente de
> suporte. O token está na variável de ambiente SUPPORT_BOT_TOKEN.

O agente usa `manage_channel` para adicionar o bot e vinculá-lo ao agente
indicado. Essa capacidade é deliberadamente protegida: ela só mexe em bots com
nome (nunca o padrão protegido), é instruída a confirmar os detalhes com você
primeiro, e é uma ferramenta arriscada, então a chamada passa pela barreira
de permissão. E o mais importante: você dá o **nome** de uma variável de ambiente que
contém o token, nunca o token em si, de modo que o segredo nunca passa pelo chat
nem pelo modelo. Depois da mudança, o bot em execução entra no ar ao vivo, sem
reiniciar.

## Decisões de arquitetura que simplificam o uso

### Auto-hospedado, suas chaves, seus dados

O Pepe nunca embute um modelo ou uma chave de API. Você o roda na sua própria
máquina ou servidor, e o aponta para o provedor que quiser. Nada de uma conversa
sai da sua infraestrutura, exceto as chamadas que você configura para o endpoint
do modelo que escolheu.

### Agnóstico de modelo

Como cada provedor é alcançado pelo mesmo protocolo Chat Completions da OpenAI,
trocar de modelo é uma mudança de configuração, não de código. OpenAI, OpenRouter,
Together, Groq, DeepSeek, Mistral e servidores locais como Ollama, LM Studio e
vLLM funcionam todos do mesmo jeito. Uma conexão de modelo pode até listar modelos
de fallback, então uma falha transitória (um limite de taxa, um erro de servidor,
uma oscilação de rede) em um provedor passa discretamente para o próximo, enquanto
uma chave inválida ou uma requisição malformada falha na hora, em vez de tentar de
novo sem propósito.

### Sem banco de dados

Toda a configuração (conexões de modelo, agentes, canais, agendamentos) vive em um
único arquivo JSON em `~/.pepe/config.json`. Não há nada para provisionar nem nada
para migrar. Segredos são escritos como referências `${ENV_VAR}` e expandidos
apenas na leitura, então suas chaves nunca são escritas de volta no disco em texto
puro.

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

### Conversas isoladas

Cada conversa roda como seu próprio processo leve e supervisionado, identificado
por um id de sessão. Muitas correm lado a lado, e uma queda em uma nunca afeta a
outra, então um único turno ruim não pode derrubar o resto dos seus agentes.

### Multiempresa quando você precisa

O trabalho pode ser limitado a uma **empresa**, isolando agentes, canais, modelos
e uso por cliente. Se você nunca ativar, tudo vive no escopo padrão, chamado
**Principal**, e você pode ignorar as empresas por completo.

## Para onde ir depois

- [Início rápido](../quickstart/). Instale o Pepe, conecte um modelo e rode seu
  primeiro agente em alguns minutos.
- [Agentes e ferramentas](../agents/). Do que um agente é feito e como ele decide
  usar ferramentas.
- [API HTTP](../api/). Comande o Pepe a partir de qualquer cliente compatível com
  OpenAI, tanto pela via de requisição/resposta quanto pela de streaming.
- [Canais](../channels/). Coloque um agente no Telegram, WhatsApp, Slack e mais.
- [Tarefas agendadas](../scheduled/). Rode agentes em um agendamento recorrente.
- [Segurança e permissões](../security/). A barreira de permissão, o sandbox e como
  manter um agente dentro de limites seguros.
