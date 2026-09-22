---
title: Mensagens de voz
description: Uma mensagem de voz chega ao agente já como texto, transcrita à entrada, antes mesmo de a execução começar.
---

## Mensagens de voz

Envia uma mensagem de voz no Telegram ou no WhatsApp, ou no Discord (como anexo de um comando de barra, ou dita diretamente num canal que o bot escute), e o agente recebe **texto**. O áudio é transcrito logo à chegada, antes de existir sessão e antes de qualquer decisão de encaminhamento, por isso o que chega ao agente não é diferente de uma mensagem normal.

Isto não foi sempre assim. Antes, o gateway limitava-se a gravar o ficheiro na área de trabalho do agente e a entregar-lhe o caminho, deixando-o a ele descobrir como escutar aquilo: procurar um transcritor, instalá-lo, correr-lho, ler o resultado. Cada mensagem de voz virava um pequeno projeto de investigação, lento e inconsistente de cada vez que acontecia, e ainda por cima gastava uma barreira de permissão só para ler uma mensagem que tinha acabado de chegar.

### Não há nada para configurar

Se já tens uma ligação de modelo à OpenAI ou à Groq, a transcrição já funciona sozinha. O Pepe reaproveita essa mesma credencial, mas pede ao fornecedor o modelo de transcrição (`whisper-1` na OpenAI, `whisper-large-v3-turbo` na Groq) em vez do modelo de chat com que a ligação foi configurada. Basta enviar a mensagem de voz para ela ser respondida; não há nada a preparar antes.

### Em que canais funciona

**Telegram, WhatsApp e Discord** fazem passar um anexo pela mesma porta: áudio dá uma transcrição, um documento dá texto, e uma imagem segue para um modelo com visão como imagem. As definições desta página são partilhadas pelos três, pelo que configurar a transcrição uma vez chega para todos.

Há dois pormenores a reter:

- No **WhatsApp** o que chega é um id de média, não o ficheiro. O Pepe resolve esse id na Graph API com o mesmo token de acesso que a ligação já usa, sem configuração adicional. A Meta limita a média recebida por tipo (16 MB para áudio, 5 MB para imagens, 100 MB para documentos), e o próprio limite de 20 MB do Pepe aplica-se por cima.
- No **Discord** há dois caminhos separados, e uma ligação pode oferecer um deles ou ambos. A **opção de anexo** de um comando de barra funciona em qualquer ligação: dá ao teu comando uma opção de anexo e `/ask file:<clip>` funciona, com ou sem texto escrito ao lado. Uma mensagem de voz gravada diretamente num canal, ou enviada numa DM, precisa do opt-in `--gateway`/`--bot-token` da ligação (ver [Discord](../discord/)); sem isso, essa mensagem nunca chega ao Pepe e não há forma de a transcrever.

Slack, Microsoft Teams e Google Chat continuam a receber apenas texto.

### Como a rota é escolhida

O Pepe experimenta estas rotas por esta ordem, sabendo que qualquer uma delas pode simplesmente não existir:

1. **`media.audio.model`**: uma ligação de modelo, referida pelo nome. A cadeia de `fallbacks` dessa ligação aplica-se também aqui, por isso o failover não custa nada a mais.
2. **`media.audio.command`**: um comando local, como `whisper-cli -f {file}`, onde `{file}` é substituído pelo caminho do áudio. Esta rota é tentada *antes* da deteção automática, de propósito: quem configura um transcritor local fá-lo precisamente para manter o áudio fora da rede, e passar-lhe à frente para chamar um fornecedor externo anularia essa intenção.
3. **Deteção automática**: a rota sem qualquer configuração descrita acima.
4. **Nada disponível**: o ficheiro segue para o agente, que se desenrasca com as ferramentas que tiver à mão. Este caminho existe apenas como rede de segurança, nunca como porta de entrada.

### Configurar

Aponta a transcrição para uma ligação de modelo específica, ou para um comando local, pela CLI:

```bash
pepe media audio --model groq --language pt --echo true
pepe media audio --command "whisper-cli -f {file}"   # mantém o áudio na máquina
pepe media audio off                                 # volta à deteção automática
```

Com `--echo true`, a transcrição é devolvida ao chat, para quem falou conferir se foi bem entendido. As mesmas opções estão disponíveis na página Config do painel, e no `pepe setup`, em **Media**.

### Porque é que transcrever primeiro faz diferença

Como o texto já existe antes de o encaminhamento correr, o encaminhamento consegue lê-lo, e daí nascem duas coisas que antes eram impossíveis, enquanto a transcrição só surgia dentro do próprio turno do agente:

- **Um comando de barra dito em voz alta funciona.** Diz `/help` ou `/stop` numa mensagem de voz e o comando corre tal como se o tivesses escrito, em vez de se transformar num turno do agente a lidar com um ficheiro qualquer numa pasta.
- **Um bot num grupo pode ser interpelado pela voz.** Num grupo que exige menção, a barreira lê agora as **palavras** ditas em vez de uma legenda. Uma mensagem de voz nunca teve legenda, por isso, antes disto, simplesmente não havia nada para essa barreira ler, e não era possível dirigires-te ao bot só a falar.

<div class="note"><strong>O áudio vira texto; a fotografia vira visão.</strong> A fala é transcrita mesmo à porta de entrada. Uma fotografia é enviada ao modelo como imagem que ele consegue mesmo ver (num modelo com visão, como se explica abaixo). Um documento é extraído para texto.</div>

## Responder de volta

Também é possível responder a uma mensagem de voz com outra mensagem de voz. Vem desligado por predefinição; ativa-se apontando `media.tts` a uma ligação de modelo que sirva um `/audio/speech` compatível com a OpenAI:

```bash
pepe media tts --model openai --voice nova
pepe media tts off
```

O registo que fica a valer continua a ser a resposta em texto; o áudio é apenas um extra, com um limite de duração para que uma resposta longa nunca se transforme num clipe de cinco minutos. Uma falha no TTS passa despercebida de propósito: como a resposta em texto já foi enviada, nada se perde de facto, só não ganha voz naquele turno em particular. As mesmas opções vivem na página Config do painel, e no `pepe setup`, em **Media**.

## Fotografias

Envia uma fotografia no Telegram, no WhatsApp ou no Discord e, com um **modelo com visão**, o agente vê mesmo a imagem, não um nome de ficheiro qualquer. Até há pouco tempo recebia apenas uma linha de texto a dizer que "o utilizador enviou uma fotografia, guardada em `…`", sem a imagem em si alguma vez chegar ao modelo, o que deixava o agente a adivinhar, ou a inventar, o que lá estava. Agora a imagem segue junto com a mensagem.

Isto fica desligado a não ser que digas explicitamente que o modelo consegue ver. Nem todos os endpoints compatíveis com a OpenAI aceitam imagens, e mandar uma para um modelo só de texto dá erro, por isso a visão é opcional, ligação a ligação:

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

Com `vision` ativado, uma fotografia (com ou sem legenda) chega ao modelo como imagem, logo no turno em que é recebida. Funciona da mesma forma em ligações compatíveis com a OpenAI, com a Anthropic, e com Responses/Codex. A imagem só acompanha esse turno em concreto: tal como acontece com a transcrição, o registo que fica é a resposta do agente sobre ela, não os bytes propriamente ditos, por isso nunca faz a sessão inchar nem é reenviada a cada novo turno. Um modelo sem `vision` volta simplesmente ao comportamento antigo, com o caminho do ficheiro no prompt para o agente abrir com as suas próprias ferramentas.

O Telegram já envia cada fotografia em vários tamanhos pré-calculados, o que permite ao Pepe escolher o maior que ainda caiba no limite de bytes, sem precisar de nenhuma biblioteca de processamento de imagem instalada. Um álbum de fotografias chega como várias imagens em conjunto. Os limites vivem sob `media.image`, e ambos têm predefinição:

- `max_mb`: o tamanho máximo aceite para uma imagem, em megabytes. Por omissão, `5`. Uma fotografia demasiado grande, ou de um tipo não suportado, cai de volta para o prompt com o caminho do ficheiro.
- `max_parts`: quantas imagens um único turno pode transportar, para o caso dos álbuns. Por omissão, `4`. O que passar disso é entregue apenas como caminho de ficheiro.

```json
{
  "media": {
    "image": { "max_mb": 5, "max_parts": 4 }
  }
}
```

### Configuração

Todas as chaves são opcionais e vivem sob `media.audio`, no `~/.pepe/config.json`:

- `model`: o nome de uma ligação de modelo a usar para transcrever.
- `command`: um transcritor local, onde `{file}` é substituído pelo caminho do áudio.
- `language`: uma indicação de idioma passada ao fornecedor.
- `max_mb`: limite de tamanho para o ficheiro recebido. Por omissão, `20`.
- `timeout`: quanto tempo uma transcrição pode demorar, em segundos. Por omissão, `60`.
- `echo`: devolve a transcrição ao chat como `📝 ...`, para quem falou conferir se foi bem entendido.

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

Para manter o áudio dentro da própria máquina, usa um comando em vez de uma ligação:

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

### Salvaguardas

- **Um ficheiro com menos de 1 KB é recusado antes de sequer se fazer um pedido.** A esse tamanho está vazio ou truncado, não apenas silencioso, e nenhum transcritor teria algo de útil a dizer sobre ele; recusar não custa nada, mas enviá-lo custaria um pedido.
- **Um ficheiro acima do `max_mb` é recusado da mesma forma**, antes de custar um pedido.
- **Um comando encravado é abandonado ao fim do `timeout`**, em vez de deixar a conversa inteira à espera dele.
- **Um áudio sem fala nenhuma recebe uma resposta curta**, não um turno completo do agente: o ficheiro foi lido, simplesmente não havia lá nada, e tratar isso como uma mensagem normal só produziria uma resposta confusa.
