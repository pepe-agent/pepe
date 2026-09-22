---
title: Mensagens de voz
description: Um áudio chega como texto para o agente. A transcrição acontece na entrada, antes de qualquer execução começar.
---

## Mensagens de voz

Manda um áudio no Telegram ou no WhatsApp, ou no Discord (como anexo de um
comando de barra, ou falado direto num canal que o bot escuta), e o que o
agente recebe é **texto**. A transcrição acontece na chegada, antes mesmo de existir uma
sessão e antes de qualquer decisão de roteamento, então o agente sempre vê
uma mensagem comum, como qualquer outra.

Nem sempre foi assim. Antes, o gateway apenas salvava o arquivo no
workspace do agente e passava o caminho adiante, deixando por conta dele
descobrir como "escutar" aquilo: achar um transcritor, instalar, rodar, ler
a saída. Cada áudio recebido virava um pequeno projeto de pesquisa, lento,
inconsistente de uma vez para outra, e que ainda gastava uma barreira de
permissão só para ler uma mensagem que tinha acabado de chegar.

### Não há nada para configurar

Se você já tem uma conexão de modelo com a OpenAI ou com a Groq, a
transcrição simplesmente já funciona: o Pepe reaproveita essa mesma
credencial e pede ao provedor o modelo de transcrição dele (`whisper-1` na
OpenAI, `whisper-large-v3-turbo` na Groq), em vez do modelo de chat com o
qual a conexão foi configurada. Basta mandar o áudio que ele já vem
respondido, sem nenhum ajuste prévio.

### Em quais canais isso funciona

**Telegram, WhatsApp e Discord** tratam um anexo da mesma forma: áudio vira
transcrição, documento vira texto, e imagem vai para um modelo com visão como
imagem mesmo. Os ajustes desta página valem para os três, então basta
configurar a transcrição uma vez.

Dois detalhes que vale saber:

- No **WhatsApp**, o que chega é um id de mídia, não o arquivo. O Pepe resolve
  esse id na Graph API com o mesmo token de acesso que a conexão já usa, sem
  nenhuma configuração extra. A Meta limita mídia recebida por tipo (16 MB
  para áudio, 5 MB para imagens, 100 MB para documentos), e o próprio limite
  de 20 MB do Pepe se aplica por cima.
- No **Discord** há dois caminhos separados, e uma conexão pode oferecer um
  deles ou os dois. A **opção de anexo** de um comando de barra funciona em
  qualquer conexão: dê ao seu comando uma opção de anexo e `/ask file:<áudio>`
  funciona, com ou sem texto digitado junto. Um áudio gravado direto num
  canal, ou mandado numa DM, precisa do opt-in `--gateway`/`--bot-token` da
  conexão (veja [Discord](../discord/)); sem isso, essa mensagem nunca chega
  ao Pepe e não tem como ser transcrita.

Slack, Microsoft Teams e Google Chat continuam recebendo apenas texto.

### Como a rota é escolhida

O Pepe segue esta ordem de tentativas, e é normal faltar algum dos passos:

1. **`media.audio.model`**: uma conexão de modelo, referenciada pelo nome.
   A cadeia de `fallbacks` daquela conexão também vale aqui, então o
   failover sai de graça.
2. **`media.audio.command`**: um comando local, por exemplo `whisper-cli -f
   {file}`, onde `{file}` é trocado pelo caminho do áudio. Esse comando é
   tentado *antes* da detecção automática, de propósito: quem configura um
   transcritor local o faz justamente para manter o áudio fora da rede, e
   pular essa etapa para chamar um provedor externo anularia a ideia toda.
3. **Detecção automática**: a rota sem nenhuma configuração, descrita acima.
4. **Nada disponível**: o arquivo cai no colo do agente, que se vira com as
   próprias ferramentas. Esse caminho continua existindo como rede de
   segurança, mas não é a porta de entrada normal.

### Configurando

Dá para apontar a transcrição para uma conexão de modelo específica, ou para
um comando local, pela CLI:

```bash
pepe media audio --model groq --language pt --echo true
pepe media audio --command "whisper-cli -f {file}"   # mantém o áudio na máquina
pepe media audio off                                 # volta para detecção automática
```

`--echo true` devolve a transcrição para o próprio chat, assim quem falou
consegue conferir se foi bem entendido. As mesmas opções aparecem na página
Config do painel, e no `pepe setup` dentro de **Mídia**.

### Por que transcrever primeiro faz diferença

Como o texto já existe antes de o roteamento entrar em ação, o roteamento
consegue ler esse texto normalmente. Disso saem duas consequências, nenhuma
das duas possível enquanto a transcrição só surgia dentro do turno do
próprio agente:

- **Um comando de barra falado funciona de verdade.** Diga "/help" ou
  "/stop" dentro de um áudio, e o comando roda exatamente como se tivesse
  sido digitado, em vez de virar um turno inteiro do agente só para
  interpretar um arquivo perdido num diretório.
- **Um bot em grupo pode ser chamado só de voz.** Num grupo que exige
  menção, a barreira de entrada lê as **palavras** ditas, não uma legenda.
  Um áudio não carrega legenda nenhuma, então antes disso simplesmente não
  havia nada para essa barreira ler, e chamar o bot só falando era
  impossível.

<div class="note"><strong>Áudio vira texto; foto vira visão.</strong> A fala
é transcrita já na porta de entrada. Já uma foto é enviada ao modelo como
uma imagem que ele realmente enxerga (num modelo com suporte a visão, veja
mais abaixo). Um documento, por sua vez, é extraído direto para texto.</div>

## Respondendo de volta com voz

Dá para responder a um áudio com outro áudio. Isso vem desligado por
padrão; para ligar, basta apontar `media.tts` para uma conexão de modelo
que sirva um `/audio/speech` compatível com OpenAI:

```bash
pepe media tts --model openai --voice nova
pepe media tts off
```

O registro que fica salvo continua sendo a resposta em texto; o áudio é só
um extra, com um teto de duração para que uma resposta longa nunca vire um
clipe de cinco minutos. Se o TTS falhar, a falha é silenciosa: a resposta em
texto já saiu de qualquer forma, então nada se perde, ela só fica sem voz
naquele turno específico. As mesmas configurações estão na página Config do
painel, e no `pepe setup` em **Mídia**.

## Fotos

Envie uma foto no Telegram, no WhatsApp ou no Discord e, com um **modelo que
suporte visão**, o agente enxerga a imagem de verdade, não apenas um nome de
arquivo. Antes disso, ele só recebia uma linha de texto do tipo "o usuário
enviou uma foto, salva em `…`", enquanto a imagem em si nunca chegava ao
modelo, deixando o agente adivinhando, ou pior, inventando o que havia
nela. Agora a imagem viaja junto com a própria mensagem.

Isso fica desligado até você avisar explicitamente que o modelo enxerga
imagens. Nem todo endpoint compatível com OpenAI aceita uma imagem, e mandar
uma para um modelo só de texto vira erro na hora, então a visão é algo que
se liga conexão por conexão:

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

Com `vision` ativado, uma foto (com ou sem legenda) chega ao modelo como
imagem já no turno em que foi enviada. Isso funciona do mesmo jeito em
conexões compatíveis com OpenAI, Anthropic e Responses/Codex. A imagem
acompanha só aquele turno específico: assim como acontece com uma
transcrição, o que fica registrado de fato é a resposta do agente sobre a
imagem, não os bytes dela, então a sessão nunca incha nem reenvia a mesma
imagem a cada novo turno. Um modelo sem `vision` simplesmente cai de volta
para o comportamento antigo: o caminho do arquivo entra no prompt, e cabe
ao agente abri-lo com as próprias ferramentas.

O Telegram já manda cada foto em vários tamanhos pré-redimensionados, então
o Pepe escolhe o maior que ainda cabe dentro do teto de bytes, sem precisar
de nenhuma biblioteca de processamento de imagem instalada. Um álbum inteiro
de fotos chega como várias imagens juntas. Os dois limites que controlam
isso ficam em `media.image`, ambos com valor padrão:

- `max_mb`: o tamanho máximo aceito por imagem, em megabytes. O padrão é
  `5`. Uma foto grande demais, ou de um tipo não suportado, cai de volta
  para o prompt com o caminho do arquivo.
- `max_parts`: quantas imagens um único turno pode carregar, para álbuns. O
  padrão é `4`. O que passar disso é entregue como caminho de arquivo.

```json
{
  "media": {
    "image": { "max_mb": 5, "max_parts": 4 }
  }
}
```

### Configuração

Todas as chaves abaixo são opcionais e ficam sob `media.audio`, no
`~/.pepe/config.json`:

- `model`: o nome de uma conexão de modelo para transcrever com ela.
- `command`: um transcritor local, onde `{file}` é substituído pelo caminho
  do áudio.
- `language`: uma dica de idioma repassada ao provedor.
- `max_mb`: limite de tamanho para um arquivo recebido. O padrão é `20`.
- `timeout`: quanto tempo uma transcrição pode levar, em segundos. O padrão
  é `60`.
- `echo`: devolve a transcrição para o chat como `📝 ...`, para quem falou
  poder conferir o que foi entendido.

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

Para manter o áudio dentro da própria máquina, use um comando em vez de uma
conexão de modelo:

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

### Proteções

- **Um arquivo com menos de 1 KB é recusado antes de qualquer requisição.**
  Nesse tamanho, ele está vazio ou truncado, não apenas silencioso, e
  nenhum transcritor teria nada de útil a dizer sobre ele. Recusar não
  custa nada; enviar custaria uma requisição inteira.
- **Um arquivo acima de `max_mb` é recusado do mesmo jeito**, também antes
  de gastar uma requisição.
- **Um comando travado é abandonado ao bater o `timeout`**, em vez de
  prender a conversa inteira atrás dele.
- **Um áudio sem nenhuma fala recebe uma resposta curta**, não um turno
  completo do agente. O arquivo foi lido normalmente, só não havia nada
  dentro dele, e tratar isso como uma mensagem de verdade só geraria uma
  resposta sem sentido.
