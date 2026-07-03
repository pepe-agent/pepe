---
title: Mensagens de voz
description: Um áudio chega como texto. A transcrição acontece na entrada, antes de o agente rodar.
---

## Mensagens de voz

Mande um áudio para o seu bot do Telegram e o agente recebe **texto**. O áudio é
transcrito na chegada, antes de existir uma sessão e antes de qualquer decisão de
roteamento, então o que chega ao agente é uma mensagem comum.

Nem sempre foi assim. O gateway salvava o arquivo no workspace do agente e entregava o
caminho, deixando o agente descobrir sozinho como escutar: achar um transcritor, instalar,
rodar, ler a saída. Cada áudio virava um pequeno projeto de pesquisa. Era lento, saía
diferente a cada vez, e gastava uma barreira de permissão só para ler a mensagem que
acabara de chegar.

### Nada para configurar

Se você já tem uma conexão de modelo com a OpenAI ou com a Groq, a transcrição já
funciona. O Pepe reaproveita essa credencial e pede ao provedor o modelo de transcrição
dele (`whisper-1` na OpenAI, `whisper-large-v3-turbo` na Groq) em vez do modelo de chat com
que a conexão foi configurada. Mande um áudio e ele é respondido. Não há nada a ajustar.

### Como a rota é escolhida

O Pepe tenta estas rotas nesta ordem, e qualquer uma delas pode estar ausente:

1. **`media.audio.model`**: uma conexão de modelo, referenciada pelo nome. A cadeia de
   `fallbacks` daquela conexão vale aqui também, então o failover não custa nada a mais.
2. **`media.audio.command`**: um comando local, por exemplo `whisper-cli -f {file}`. O
   `{file}` é substituído pelo caminho do áudio. Isso vem *antes* da detecção automática, e
   é de propósito: quem configurou um transcritor local fez isso para o áudio não sair da
   máquina, e passar por cima disso para chamar um provedor anularia o propósito.
3. **Detecção automática**: a rota sem configuração descrita acima.
4. **Nada disponível**: o arquivo vai para o agente, que se vira com as ferramentas que
   tem. Esse caminho continua existindo como rede de segurança; ele não é a porta de
   entrada.

### Por que transcrever antes muda tudo

Como as palavras existem antes de o roteamento rodar, o roteamento consegue lê-las. Daí
saem duas consequências, nenhuma delas possível enquanto a transcrição só aparecia dentro
do turno do agente:

- **Um comando de barra falado funciona.** Fale `/help` ou `/stop` num áudio e o comando é
  executado, exatamente como se você tivesse digitado, em vez de virar um turno do agente
  sobre um arquivo largado num diretório.
- **Um bot em grupo pode ser chamado por voz.** Num grupo que exige menção, a barreira lê
  as **palavras** em vez da legenda. Um áudio não tem legenda, então antes disso não havia
  nada para a barreira ler, e era impossível endereçar o bot falando.

<div class="note"><strong>Áudio vira texto; foto vira visão.</strong> A fala é transcrita na
porta de entrada. Uma foto é enviada ao modelo como uma imagem que ele consegue de fato ver
(num modelo com visão, veja abaixo). Um documento é extraído para texto.</div>

## Fotos

Envie uma foto ao seu bot do Telegram e, num **modelo com visão**, o agente vê a imagem de
verdade, não um nome de arquivo. Antes ele recebia só uma linha de texto ("o usuário enviou
uma foto, salva em `…`") enquanto a imagem em si nunca chegava ao modelo, então o agente
ficava adivinhando, ou inventando, o que havia nela. Agora a imagem vai junto com a mensagem.

Fica desligado a menos que você diga que o modelo enxerga. Nem todo endpoint compatível com a
OpenAI aceita uma imagem, e enviar uma para um modelo só de texto é um erro, então a visão é
opcional por conexão:

```json
{
  "models": {
    "gpt4o": {
      "base_url": "https://api.openai.com/v1",
      "api_key": "${OPENAI_API_KEY}",
      "model": "gpt-4o",
      "vision": true
    }
  }
}
```

Com `vision` ativo, uma foto (com ou sem legenda) chega ao modelo como imagem no turno em que
é recebida. Funciona igual em conexões compatíveis com a OpenAI, Anthropic e Responses/Codex.
A imagem acompanha apenas aquele turno: como uma transcrição, o registro que fica é a resposta
do agente sobre ela, não os bytes, então nunca incha a sessão nem é reenviada a cada turno. Um
modelo sem `vision` volta ao comportamento antigo (o caminho do arquivo no prompt, para o
agente abrir com as próprias ferramentas).

O Telegram já envia cada foto em vários tamanhos pré-redimensionados, então o Pepe escolhe o
maior que cabe no teto de bytes, sem nenhuma biblioteca de processamento de imagem para
instalar. Um álbum de fotos é enviado como várias imagens juntas. Os limites ficam em
`media.image` e ambos têm padrões:

- `max_mb`: a maior imagem aceita, em megabytes. Padrão `5`. Uma foto grande demais (ou de um
  tipo não suportado) volta ao prompt com o caminho do arquivo.
- `max_parts`: quantas imagens um turno pode carregar, para álbuns. Padrão `4`. O que passar
  disso é entregue como caminho de arquivo.

```json
{
  "media": {
    "image": { "max_mb": 5, "max_parts": 4 }
  }
}
```

### Configuração

Todas as chaves são opcionais e ficam em `media.audio`, no `~/.pepe/config.json`:

- `model`: o nome de uma conexão de modelo com a qual transcrever.
- `command`: um transcritor local. O `{file}` é substituído pelo caminho do áudio.
- `language`: uma dica de idioma passada ao provider.
- `max_mb`: limite de tamanho para o arquivo recebido. O padrão é `20`.
- `timeout`: quanto tempo uma transcrição pode levar, em segundos. O padrão é `60`.
- `echo`: devolve a transcrição ao chat como `📝 ...`, para quem falou conferir o que foi
  entendido.

```json
{
  "media": {
    "audio": {
      "model": "groq",
      "language": "pt",
      "max_mb": 20,
      "timeout": 60,
      "echo": true
    }
  }
}
```

Para manter o áudio na máquina, use um comando em vez de uma conexão:

```json
{
  "media": {
    "audio": {
      "command": "whisper-cli -f {file}",
      "timeout": 120
    }
  }
}
```

### Guardas

- **Um arquivo abaixo de 1 KB é recusado antes de qualquer requisição.** Nesse tamanho ele
  está vazio ou truncado, não silencioso, e nenhum transcritor diria nada de útil sobre
  ele. Recusar não custa nada; enviar custa uma requisição.
- **Um arquivo acima do `max_mb` é recusado do mesmo jeito**, antes de custar uma
  requisição.
- **Um comando travado é abandonado no `timeout`**, em vez de travar a conversa que está
  atrás dele.
- **Um áudio sem fala nenhuma recebe uma resposta curta**, não um turno do agente. O
  arquivo foi lido, só não havia nada dentro dele, e responder a uma mensagem vazia só
  produziria uma resposta confusa.
