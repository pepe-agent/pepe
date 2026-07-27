# Notas da Versão — 0.11.0

Olá! Esta versão tem um tema: **conectar o Pepe a servidores MCP que não rodam na sua máquina**. Junto vieram uma página nova de documentação sobre colocar o Pepe num servidor, dois ajustes de layout no celular, e a correção de um teste que mantinha a esteira de release travada.

---

## ✨ Novidades

### Servidores MCP agora podem ser remotos

Até aqui, conectar um servidor MCP significava o Pepe **rodar um programa** na própria máquina. Para alcançar um servidor hospedado na internet, o caminho comum era instalar o Node e deixar um processo-ponte (`npx mcp-remote`) rodando ao lado. Na imagem oficial em Docker isso simplesmente não dá: ela não traz Node, e o agente não roda como root para instalar.

Agora um servidor pode ser só uma URL:

```bash
pepe mcp add memclaw --url https://memclaw.net/mcp \
  --header "Authorization: Bearer ${MEMCLAW_API_KEY}"
```

O mesmo pela página MCP do painel, ou pedindo ao próprio agente numa conversa. Daí em diante nada muda: as ferramentas continuam com nome `mcp__servidor__ferramenta`, continuam limitadas pela lista de ferramentas do agente, e cada chamada continua passando pelo pedido de permissão.

📍 *Onde usar: `pepe mcp add --url`, painel → MCP, ou pedindo ao agente*

### O protocolo se acerta sozinho

Existem duas maneiras de um servidor MCP remoto conversar, e a única forma de saber qual ele fala é tentando. O Pepe tenta a mais nova e, se o servidor não responder, tenta a antiga. Você passa a URL e pronto.

Só se a negociação errar é que existe `--transport streamable|sse` para fixar na mão. O padrão é tentar, porque errar o palpite parece exatamente uma URL quebrada, e ninguém deveria precisar saber dessa diferença para começar.

### Entrar com OAuth em servidores que não usam chave de API

Alguns servidores hospedados não aceitam chave nenhuma: exigem que você entre com sua conta. Um comando:

```bash
pepe mcp login memclaw
```

O Pepe pergunta ao servidor onde fica o serviço de autenticação dele, se cadastra lá sozinho, abre seu navegador e guarda o acesso. Nada para preencher à mão. Quando você está por SSH, sem navegador, ele imprime o link e aceita o código colado — igual aos logins de provedor de modelo que você já usa.

O acesso é renovado automaticamente quando vence, e `pepe mcp logout NOME` esquece tudo.

Um detalhe pensado de propósito: **o agente não faz esse login por você.** Ele poderia gerar um link e pedir para você clicar, que é exatamente o formato de uma mensagem de golpe. Então ele te diz qual comando rodar, e você roda.

📍 *Onde usar: `pepe mcp login`, ou o botão na página MCP do painel*

### Documentação: colocando o Pepe num servidor

A página de Docker sempre cobriu o container. Faltava o passo seguinte: domínio, HTTPS e proxy reverso. A nova página traz três receitas completas de copiar — Docker Compose com Caddy, Docker Swarm com Traefik, e Kamal — mais as quatro coisas que mudam quando o Pepe sai do `localhost` e falham em silêncio se você esquecer.

Tem também uma tabela de "não subiu, e agora": para cada sintoma (nome não resolve, 404 do proxy, certificado errado, tela de cadeado), qual camada está com o problema.

📍 *Onde ler: documentação → Administração → Publicando em um servidor*

---

## 🐛 Correções

### Ferramenta MCP que falhava era reportada como sucesso

Quando uma ferramenta de um servidor MCP falha, o servidor pode avisar isso *dentro* de uma resposta que, por fora, parece bem-sucedida. O Pepe olhava só o lado de fora, então entregava o texto do erro ao agente como se fosse um resultado bom, e ele seguia trabalhando em cima da falha. Agora é tratado como erro.

### Painel no celular: dois ajustes

O diagrama que mostra o caminho dos dados sensíveis empilhava os cartões e as setas grudados na margem esquerda, com metade da tela vazia ao lado. E o título da página inicial deixava a sigla "IA" sozinha numa linha. Os dois corrigidos.

---

## 🔧 Por baixo do capô

- Os acessos OAuth de servidores MCP ficam no banco local do Pepe, não no arquivo de configuração. Diferente de toda outra credencial, eles não podem ser uma referência de variável de ambiente: giram sozinhos, e ninguém fora do Pepe sabe o valor atual.
- Um push agora gera **uma** execução de CI em vez de duas.
- Um teste que aceitava uma mensagem destinada a outra conversa mantinha a esteira vermelha desde 23 de julho — o que significa que, nesse período, nenhuma release teria publicado imagem nem binários. Diagnosticado e corrigido.
