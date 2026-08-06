---
title: Introdução
description: O Pepe roda agentes de IA na sua própria máquina. Descreva quem eles são, conecte qualquer modelo compatível com OpenAI e deixe que façam trabalho de verdade com ferramentas. Sem servidor de banco de dados, sem dependência de fornecedor.
---

## O que é o Pepe

O Pepe roda **agentes** de IA na sua própria máquina ou servidor. Você descreve
um agente uma vez (um nome, suas instruções, as ferramentas que ele pode usar e o
modelo com que ele pensa) e o Pepe cuida do resto: quando chega um pedido, o
agente trabalha em etapas, usando suas ferramentas, até ter uma resposta de
verdade.

Agentes vivem por muito tempo: conversas, canais, tarefas em segundo plano, não
pedidos avulsos. O Pepe é construído em Elixir/OTP, uma tecnologia feita
exatamente para esse tipo de trabalho, então um servidor modesto mantém uma
equipe inteira de agentes rodando lado a lado sem gastar muita memória ou CPU.

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

Ao longo do caminho, o Pepe anuncia cada passo, então qualquer superfície pode
mostrar o progresso em tempo real: a resposta conforme ela chega em streaming
(`assistant_delta`), cada chamada de ferramenta e seu resultado (`tool_call`,
`tool_result`), a resposta final (`done`) e os erros (`error`).

Ferramentas arriscadas (qualquer uma que rode um comando ou escreva um arquivo)
podem ser configuradas para pedir sua permissão antes. Se você recusar, a
ferramenta nunca roda: o modelo só recebe um breve aviso de "negado" (e um evento
`tool_denied` é emitido), então um agente nunca age em silêncio na sua máquina
sem o seu consentimento.

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
único arquivo JSON em `~/.pepe/config.json`, fácil de ler, editar e guardar como
backup. Não há nada para instalar junto com o Pepe e nada para migrar. Segredos
são escritos como referências `${ENV_VAR}` e expandidos apenas na leitura, então
suas chaves nunca são escritas de volta no disco em texto puro.

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

Cada conversa roda separada de todas as outras. Se uma der errado, as demais nem
percebem: um único turno ruim não consegue derrubar seus outros agentes nem suas
outras conversas.

### Multiprojeto quando você precisa

O trabalho pode ser limitado a um **projeto**, isolando agentes, canais, modelos
e uso por cliente. Se você nunca optar por isso, tudo vive no **projeto default**,
para o qual todo comando recorre, e você pode ignorar os projetos por completo.

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
