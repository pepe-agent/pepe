---
title: Introdução
description: O Pepe corre agentes de IA na tua própria máquina. Descreves quem eles são, ligas qualquer modelo compatível com OpenAI, e deixa-los fazer trabalho a sério com ferramentas. Sem servidor de base de dados, sem ficar preso a um fornecedor.
---

## O que é o Pepe

O Pepe corre **agentes** de IA na tua própria máquina ou servidor. Descreves
um agente uma única vez, um nome, as suas instruções, as ferramentas que
pode usar, e o modelo com que pensa, e o Pepe trata de tudo o resto: quando
chega um pedido, o agente avança por etapas, usando as ferramentas
disponíveis, até chegar a uma resposta a sério.

Os agentes destinam-se a durar: conversas, canais, tarefas em segundo
plano, não pedidos isolados que acabam ali. O Pepe está construído em
Elixir/OTP, uma tecnologia pensada exatamente para este tipo de trabalho,
e é por isso que um servidor modesto consegue manter uma equipa inteira de
agentes a correr lado a lado sem pesar muito em memória nem em CPU.

Esse ciclo interno é o cerne de tudo. Uma simples chamada de chat devolve
texto e mais nada. Um agente já consegue fazer coisas de verdade: ler um
ficheiro, correr um comando, pesquisar na web, chamar a tua API, e depois
raciocinar sobre o que encontrou antes de continuar. O Pepe entrega-te esse
ciclo pronto a usar, em vez de teres de o montar à mão em cada novo
projeto.

```bash
pepe run "lê o package.json e diz que dependências estão desatualizadas"
```

Defines o comportamento uma única vez, e o mesmo agente fica acessível de
quatro maneiras diferentes: pelo terminal, por uma API HTTP compatível com
OpenAI, por um WebSocket com streaming, e a partir de canais de mensagens
como o Telegram ou o WhatsApp. Há ainda um painel web para navegares e
conversares diretamente do browser. Cada caso de uso é servido onde já
vive, sem teres de criar um agente novo para cada canal.

## O ciclo de chamada de ferramentas

Eis o ciclo que o Pepe corre a cada turno da conversa:

1. Envia a conversa, junto com as definições das ferramentas do agente,
   para o modelo.
2. Se o modelo devolver chamadas a ferramentas, corre cada uma delas e
   recolhe a respetiva saída.
3. Junta a mensagem do assistente e os resultados dessas ferramentas de
   volta à conversa.
4. Volta ao passo 1. Só para quando o modelo devolve uma resposta simples,
   ou quando o agente atinge o limite de segurança `max_iterations`.

Ao longo do caminho, o Pepe vai anunciando cada passo, para que qualquer
superfície consiga mostrar o progresso em tempo real: a resposta à medida
que vai chegando (`assistant_delta`), cada chamada a ferramenta e o seu
resultado (`tool_call`, `tool_result`), a resposta final (`done`), e os
erros (`error`).

As ferramentas de maior risco, qualquer uma que corra um comando ou
escreva num ficheiro, podem ser configuradas para pedir a tua autorização
primeiro. Se recusares, a ferramenta simplesmente não corre: o modelo
recebe só uma nota curta de "negado" (e dispara-se um evento
`tool_denied`), de forma que um agente nunca chega a atuar em silêncio na
tua máquina sem o teu consentimento.

<div class="note"><strong>Ferramentas incorporadas.</strong> Qualquer agente pode receber ferramentas como <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code> e <code>web_search</code>. És tu que escolhes quais delas cada agente recebe ao criá-lo, por isso um bot de apoio ao cliente e um agente de programação podem acabar com poderes muito diferentes.</div>

## As cinco superfícies

Um agente constrói-se uma única vez. Depois disso, o Pepe expõe-no pela
superfície que melhor serve cada tarefa. Já a própria configuração e
gestão acontecem de três formas: pela CLI `pepe`, pelo painel web, e pela
conversa, falando em linguagem natural com um agente que tenha a
ferramenta de gestão certa para isso.

### CLI

O comando `pepe` é a forma de configurar tudo e de correr agentes
diretamente a partir de um terminal. As execuções pontuais transmitem a
resposta logo para a saída padrão, e o `pepe chat` abre uma sessão
interativa que se lembra da conversa toda.

```bash
pepe run assistant "resume o git log da última semana"
pepe chat assistant
```

### Painel web

Corre o servidor e abre o painel num browser para conversares com um
agente, navegares por sessões anteriores, e giras agentes, ligações a
modelos, canais, tarefas agendadas, utilização e traces, tudo numa
interface de apontar e clicar. Em localhost fica aberto por omissão;
podes protegê-lo atrás de uma palavra-passe de operador quando o expuseres
para fora.

```bash
pepe serve --port 4000
# depois abre http://localhost:4000
```

### API HTTP compatível com OpenAI

Arranca o servidor e o Pepe passa a falar o protocolo Chat Completions da
OpenAI, por isso qualquer SDK da OpenAI, o LangChain, ou até um simples
`curl`, conseguem falar com ele sem precisar de nenhum adaptador. Serve
`POST /v1/chat/completions` e `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "que ficheiros existem neste projeto?"}]
  }'
```

Aponta um cliente OpenAI já existente para `http://localhost:4000/v1` e o
nome do modelo passa a ser o nome do teu agente. Vê [a página da API
HTTP](../api/) para perceberes streaming, eventos de ferramentas e
autenticação.

### WebSocket

Para conversas ao vivo, token a token, numa app web ou móvel, liga-te por
WebSocket e subscreve o tópico do teu agente (`agent:<name>`). Recebes o
texto do assistente à medida que é transmitido, mais um evento por cada
chamada de ferramenta e o respetivo resultado. Os detalhes, com um exemplo
de cliente, estão na [página da API](../api/).

### Canais de mensagens

Coloca o mesmo agente à frente de utilizadores a sério, nas plataformas
onde já estão. O Pepe já traz gateways prontos para Telegram, WhatsApp,
Slack, Discord, Microsoft Teams e Google Chat, além de um webhook de
entrada genérico para tudo o resto. Cada canal liga-se a um agente e
mantém a sua própria memória de conversa por utilizador. Vê [a página de
canais](../channels/).

## Definir um agente

Um agente não é mais do que um nome, um prompt de sistema, uma lista de
ferramentas e um modelo. Cria um pela CLI:

```bash
pepe agent add assistant \
  --prompt "És o Pepe, um agente de programação prestável." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

Também podes fazer isto no painel web, na página **Agents**, que já traz
um formulário para a persona, o modelo e a seleção de ferramentas.

### Fá-lo pela conversa

Um agente que tenha a ferramenta `manage_agent` consegue criar e moldar
outros agentes diretamente numa conversa. Basta enviares-lhe uma mensagem
simples:

> Tu: Cria um agente novo chamado "researcher", cuja função é vasculhar
> documentação e resumir descobertas, e dá-lhe as ferramentas web_search e
> fetch_url.

O agente usa o `manage_agent` para `create` o agente novo, definir a
persona dele e acrescentar cada ferramenta pedida. O `manage_agent` é uma
capacidade deliberadamente protegida: só pode mexer nos agentes que lhe
foram explicitamente permitidos, é instruído a confirmar contigo cada
alteração antes de a fazer, e, por ser uma ferramenta de risco, cada
chamada continua a passar pela barreira de permissão antes de qualquer
coisa ser escrita. Assim, vês a alteração proposta e só a aprovas quando
quiseres que passe a valer.

## Ligar um modelo

O Pepe nunca traz um modelo nem uma chave incluídos. Aponta-o para
qualquer fornecedor compatível com OpenAI através de uma ligação de
modelo:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

A página **Models** do painel faz exatamente o mesmo através de um
formulário, e ainda testa a ligação antes de a guardares. Repara no
`${OPENROUTER_API_KEY}`: os segredos ficam guardados como referências a
variáveis de ambiente, e só são expandidos no momento da leitura, por isso
as tuas chaves nunca chegam a ser escritas em disco em texto simples.

## Adicionar um canal

Liga um agente a um canal de mensagens para que as pessoas consigam falar
com ele onde já estão habituadas a estar. No painel, a página **Channels**
guia-te por todo o processo de ligar um bot e escolher com que agente ele
deve falar. A partir daí, o canal passa a manter uma memória de conversa
separada por cada utilizador.

### Fá-lo pela conversa

Um agente que tenha a ferramenta `manage_channel` consegue pôr um bot do
Telegram no ar a partir de uma simples conversa:

> Tu: Adiciona um bot do Telegram chamado "support-bot" que fale com o
> agente de apoio. O token está na variável de ambiente
> SUPPORT_BOT_TOKEN.

O agente usa o `manage_channel` para adicionar o bot e ligá-lo ao agente
indicado. Esta capacidade também vem deliberadamente protegida: só toca em
bots com nome próprio, nunca no predefinido, que fica protegido à parte; é
instruído a confirmar os detalhes contigo primeiro; e, por ser uma
ferramenta de risco, a chamada passa pela barreira de permissão como
qualquer outra. O mais importante é que só dás o **nome** da variável de
ambiente que guarda o token, nunca o token em si, de modo que o segredo
nunca chega a passar pelo chat nem pelo modelo. Depois de aprovada a
alteração, o bot fica no ar de imediato, sem ser preciso reiniciar nada.

## Decisões de arquitetura que mantêm isto simples

### Auto-alojado, as tuas chaves, os teus dados

O Pepe nunca traz um modelo nem uma chave de API incluídos. Corres tudo na
tua própria máquina ou servidor, e apontas para o fornecedor que
preferires. Nada de uma conversa sai da tua infraestrutura, exceto as
chamadas que tu próprio configuraste para o endpoint do modelo escolhido.

### Independente de modelo

Como qualquer fornecedor é alcançado pelo mesmo protocolo Chat Completions
da OpenAI, trocar de modelo passa a ser uma simples alteração de
configuração, não uma mudança de código. OpenAI, OpenRouter, Together,
Groq, DeepSeek, Mistral, e servidores locais como Ollama, LM Studio e
vLLM, funcionam todos exatamente da mesma forma. Uma ligação de modelo
pode até listar modelos de recurso, de modo que uma falha passageira (um
limite de taxa, um erro do servidor, uma oscilação de rede) num fornecedor
passa discretamente para o seguinte, enquanto uma chave inválida ou um
pedido malformado falha logo de imediato, em vez de ficar a tentar sem
qualquer proveito.

### Sem servidor de base de dados

Toda a configuração (ligações de modelo, agentes, canais, agendamentos)
vive num único ficheiro JSON, em `~/.pepe/config.json`, fácil de ler,
editar e guardar como cópia de segurança. Não há nada para instalar ao
lado do Pepe, nem nada para migrar de um lado para o outro. Os segredos
ficam escritos como referências `${ENV_VAR}`, e só se expandem no momento
da leitura, por isso as tuas chaves nunca acabam escritas em disco em
texto simples.

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

Cada conversa corre à parte de todas as outras. Se uma correr mal, as
restantes nem dão por isso: um único turno com problemas não consegue
arrastar consigo os teus outros agentes, nem as tuas outras conversas.

### Multi-tenant quando precisares

O trabalho pode ficar limitado a um **projeto**, isolando agentes, canais,
modelos e utilização por essa via. Se nunca chegares a criar um projeto
próprio, tudo vive no **projeto predefinido**, que é para onde qualquer
comando recorre por omissão, e podes ignorar a existência de projetos por
completo se quiseres.

## Para onde ir a seguir

- [Início rápido](../quickstart/). Instala o Pepe, liga um modelo, e corre
  o teu primeiro agente em poucos minutos.
- [Agentes e ferramentas](../agents/). De que é feito um agente e como ele
  decide quando usar as suas ferramentas.
- [API HTTP](../api/). Comanda o Pepe a partir de qualquer cliente
  compatível com OpenAI, tanto pela via de pedido e resposta como pela de
  streaming.
- [Canais](../channels/). Coloca um agente no Telegram, no WhatsApp, no
  Slack, e em mais sítios.
- [Tarefas agendadas](../scheduled/). Corre agentes segundo um
  agendamento recorrente.
- [Segurança e permissões](../security/). A barreira de permissão, o
  sandbox, e como manter um agente dentro de limites seguros.
