---
title: Introdução
description: O Pepe é um runtime de agentes de IA auto-alojado e agnóstico de modelo. Define agentes, liga qualquer modelo compatível com OpenAI e corre um ciclo real de chamada de ferramentas, sem base de dados e sem dependência de fornecedor.
---

## O que é o Pepe

O Pepe é um runtime de agentes de IA auto-alojado, construído em Elixir. Defines
um **agente** (um nome, um prompt de sistema, um conjunto de ferramentas e uma
ligação a um modelo), e o Pepe corre-o: envia a conversa para o modelo, executa
qualquer ferramenta que o modelo peça, devolve os resultados e repete até o modelo
produzir uma resposta final.

Elixir/OTP importa aqui porque agentes são conversas longas, canais e tarefas em
segundo plano, não apenas um pedido HTTP. O Pepe consegue manter muitas sessões
supervisionadas com pouco overhead, o que ajuda a alojar uma equipa de agentes sem
inflacionar a memória nem a CPU do servidor.

Esse ciclo interno é a razão de ser de tudo. Uma simples chamada de chat devolve
texto. Um agente consegue mesmo fazer coisas: ler um ficheiro, correr um comando,
pesquisar na web, chamar a tua API, e depois raciocinar sobre o que encontrou e
continuar. O Pepe entrega-te esse ciclo como um runtime acabado, em vez de algo
que montas à mão em cada projeto.

```bash
pepe run "lê o package.json e diz que dependências estão desatualizadas"
```

Defines o comportamento uma vez, e o mesmo agente fica acessível de quatro formas:
a partir do terminal, por uma API HTTP compatível com OpenAI, por um WebSocket com
streaming, e a partir de canais de mensagens como o Telegram e o WhatsApp. Existe
ainda um painel web para navegar e conversar a partir do browser. Responde a cada
caso de uso ali onde ele já vive, sem criar um agente separado para cada canal.

## O ciclo de chamada de ferramentas

Este é o ciclo que o Pepe corre em cada turno:

1. Envia a conversa, junto com as definições de ferramentas do agente, para o
   modelo.
2. Se o modelo devolver chamadas de ferramentas, executa cada uma e recolhe a
   saída.
3. Anexa a mensagem do assistente e os resultados das ferramentas à conversa.
4. Volta ao passo 1. Para quando o modelo devolve uma resposta simples, ou quando
   o agente atinge o seu limite de segurança `max_iterations`.

Pelo caminho, o runtime emite eventos de ciclo de vida para que qualquer
superfície possa mostrar o progresso em tempo real: fragmentos de texto em
streaming (`assistant_delta`), um turno completo do assistente (`assistant`),
cada chamada de ferramenta (`tool_call`), cada resultado de ferramenta
(`tool_result`), a resposta final (`done`) e os erros (`error`). As superfícies
com streaming mostram os tokens à medida que chegam.

Ferramentas arriscadas (qualquer uma que corra um comando ou escreva um ficheiro)
podem passar por um portão de permissão que pede ao utilizador para aprovar antes
de a ferramenta correr. Se o utilizador recusar, o runtime emite um evento
`tool_denied` e entrega ao modelo uma breve mensagem de "negado" em vez de correr
a ferramenta, de modo que um agente nunca atua em silêncio na tua máquina sem o
teu consentimento.

<div class="note"><strong>Ferramentas incorporadas.</strong> Cada agente pode receber ferramentas como <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code> e <code>web_search</code>. Escolhes quais é que cada agente recebe ao criá-lo, por isso um bot de apoio e um agente de programação podem ter poderes muito diferentes.</div>

## As quatro superfícies

Constróis um agente uma vez. O Pepe expõe-o depois pela superfície que melhor
serve a tarefa. A configuração e a gestão, por sua vez, acontecem de três
maneiras: a CLI `pepe`, o painel web e pela conversa (falando em linguagem natural com
um agente que possui a ferramenta de gestão adequada).

### CLI

O comando `pepe` é a forma de configurares as coisas e de correres agentes a
partir de um terminal. As execuções pontuais transmitem a resposta diretamente
para a saída padrão, e `pepe chat` abre uma sessão interativa que se lembra da
conversa.

```bash
pepe run assistant "resume o git log da última semana"
pepe chat assistant
```

### Painel web

Corre o servidor e abre o painel num browser para conversar com um agente, navegar
por sessões anteriores e gerir agentes, ligações a modelos, canais, tarefas
agendadas, utilização e traces por uma interface de apontar e clicar. Em localhost
está aberto por omissão; podes protegê-lo atrás de uma palavra-passe de operador
quando o expuseres.

```bash
pepe serve --port 4000
# depois abre http://localhost:4000
```

### API HTTP compatível com OpenAI

Arranca o servidor e o Pepe fala o protocolo Chat Completions da OpenAI, por isso
qualquer SDK da OpenAI, LangChain ou um simples `curl` conseguem falar com ele sem
adaptador. Serve `POST /v1/chat/completions` e `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "que ficheiros existem neste projeto?"}]
  }'
```

Aponta um cliente OpenAI existente para `http://localhost:4000/v1` e o nome do
modelo passa a ser o nome do teu agente. Vê [a página da API HTTP](../api/) para
streaming, eventos de ferramentas e autenticação.

### WebSocket

Para conversas ao vivo, token a token, numa app web ou móvel, liga-te por um
WebSocket e subscreve o tópico do teu agente (`agent:<name>`). Recebes o texto do
assistente à medida que é transmitido, além de eventos para cada chamada e
resultado de ferramenta. Os detalhes e um exemplo de cliente estão na [página da
API](../api/).

### Canais de mensagens

Coloca o mesmo agente à frente de utilizadores reais nas plataformas que eles já
usam. O Pepe traz gateways para Telegram, WhatsApp, Slack, Discord, Microsoft
Teams e Google Chat, além de um webhook de entrada genérico para qualquer outra
coisa. Cada canal liga-se a um agente e mantém a sua própria memória de conversa
por utilizador. Vê [a página de canais](../channels/).

## Definir um agente

Um agente é apenas um nome, um prompt de sistema, uma lista de ferramentas e um
modelo. Cria um pela CLI:

```bash
pepe agent add assistant \
  --prompt "És o Pepe, um agente de programação prestável." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

Também podes fazê-lo no painel web, na página **Agents**, que inclui um formulário
para a persona, o modelo e a seleção de ferramentas.

### Fá-lo pela conversa

Um agente que possui a ferramenta `manage_agent` consegue criar e moldar outros
agentes diretamente a partir de uma conversa. Envia-lhe uma mensagem simples:

> Tu: Cria um novo agente chamado "researcher" cuja função é vasculhar a
> documentação e resumir descobertas, e dá-lhe web_search e fetch_url.

O agente usa `manage_agent` para `create` o novo agente, definir a sua persona e
adicionar cada ferramenta. `manage_agent` é uma capacidade protegida: o agente só
pode mexer nos agentes da sua própria lista de permitidos, é instruído a confirmar
as alterações contigo primeiro, e por ser uma ferramenta arriscada, cada chamada
passa ainda pelo portão de permissão antes de algo ser escrito. Assim vês a
alteração proposta e podes aprová-la antes de ela ter efeito.

## Ligar um modelo

O Pepe nunca inclui um modelo ou uma chave. Aponta-o para qualquer fornecedor
compatível com OpenAI através de uma ligação de modelo:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model anthropic/claude-3.5-sonnet \
  --default
```

A página **Models** do painel faz o mesmo com um formulário, e pode testar uma
ligação antes de a guardares. Repara no `${OPENROUTER_API_KEY}`: os segredos são
guardados como referências a variáveis de ambiente e expandidos apenas na leitura,
por isso as tuas chaves nunca são escritas de volta no disco em texto simples.

## Adicionar um canal

Liga um agente a um canal de mensagens para que as pessoas possam falar com ele
onde já estão. No painel, a página **Channels** guia-te pela ligação de um bot e
pela escolha de com que agente ele conversa. O canal mantém então uma memória de
conversa separada por utilizador.

### Fá-lo pela conversa

Um agente que possui a ferramenta `manage_channel` consegue levantar um bot do
Telegram a partir de uma conversa:

> Tu: Adiciona um bot do Telegram chamado "support-bot" que fala com o agente de
> apoio. O token está na variável de ambiente SUPPORT_BOT_TOKEN.

O agente usa `manage_channel` para adicionar o bot e ligá-lo ao agente indicado.
Esta capacidade é deliberadamente protegida: só mexe em bots com nome (nunca o
predefinido protegido), é instruída a confirmar os detalhes contigo primeiro, e é
uma ferramenta arriscada, por isso a chamada passa pelo portão de permissão. E o
mais importante: dás o **nome** de uma variável de ambiente que contém o token,
nunca o token em si, de modo que o segredo nunca passa pelo chat nem pelo modelo.
Depois da alteração, o bot em execução entra no ar ao vivo, sem reiniciar.

## Decisões de arquitetura que simplificam a utilização

### Auto-alojado, as tuas chaves, os teus dados

O Pepe nunca inclui um modelo ou uma chave de API. Corre-o na tua própria máquina
ou servidor, e apontas para o fornecedor que quiseres. Nada de uma conversa sai da
tua infraestrutura, exceto as chamadas que configuras para o endpoint do modelo
que escolheste.

### Agnóstico de modelo

Como cada fornecedor é alcançado pelo mesmo protocolo Chat Completions da OpenAI,
trocar de modelo é uma alteração de configuração, não de código. OpenAI,
OpenRouter, Together, Groq, DeepSeek, Mistral e servidores locais como Ollama, LM
Studio e vLLM funcionam todos da mesma forma. Uma ligação de modelo pode até listar
modelos de reserva, por isso uma falha transitória (um limite de taxa, um erro de
servidor, uma oscilação de rede) num fornecedor passa discretamente para o
seguinte, enquanto uma chave inválida ou um pedido malformado falha de imediato,
em vez de tentar de novo sem propósito.

### Sem base de dados

Toda a configuração (ligações de modelo, agentes, canais, agendamentos) vive num
único ficheiro JSON em `~/.pepe/config.json`. Não há nada para aprovisionar nem
nada para migrar. Os segredos são escritos como referências `${ENV_VAR}` e
expandidos apenas na leitura, por isso as tuas chaves nunca são escritas de volta
no disco em texto simples.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "anthropic/claude-3.5-sonnet"
    }
  }
}
```

### Conversas isoladas

Cada conversa corre como o seu próprio processo leve e supervisionado,
identificado por um id de sessão. Muitas correm lado a lado, e uma falha numa
nunca toca noutra, por isso um único turno defeituoso não consegue deitar abaixo o
resto dos teus agentes.

### Multiempresa quando precisas

O trabalho pode ser limitado a uma **empresa**, isolando agentes, canais, modelos
e utilização por empresa. Se nunca ativares, tudo vive no âmbito predefinido,
chamado **Principal**, e podes ignorar as empresas por completo.

## Para onde ir a seguir

- [Início rápido](../quickstart/). Instala o Pepe, liga um modelo e corre o teu
  primeiro agente em poucos minutos.
- [Agentes e ferramentas](../agents/). De que é feito um agente e como ele decide
  usar ferramentas.
- [API HTTP](../api/). Comanda o Pepe a partir de qualquer cliente compatível com
  OpenAI, tanto pela via de pedido/resposta como pela de streaming.
- [Canais](../channels/). Coloca um agente no Telegram, WhatsApp, Slack e mais.
- [Tarefas agendadas](../scheduled/). Corre agentes num agendamento recorrente.
- [Segurança e permissões](../security/). O portão de permissão, o sandbox e como
  manter um agente dentro de limites seguros.
