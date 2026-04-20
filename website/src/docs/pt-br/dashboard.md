---
title: Painel
description: Use a interface web local para inspecionar e gerenciar agentes, modelos, canais e execuções.
---

O painel é a interface web local iniciada por `pepe serve`. Use-o para conversar com agentes, inspecionar traces, gerenciar conexões de modelo, configurar canais, revisar tarefas agendadas e gerar tokens de API sem editar JSON à mão.

## Mantendo ele no ar

O `pepe serve` roda em primeiro plano - fechar o terminal ou sair da sessão para o processo, e o painel junto. Pra um deploy de verdade, instale como serviço persistente em segundo plano: launchd no macOS, systemd `--user` no Linux. Ele sobrevive a logout/reboot e reinicia sozinho se cair.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Só funciona no binário `pepe` instalado, não em `mix pepe serve install`. Se suas conexões de modelo referenciam segredos `${ENV_VAR}`, o `install` lista quais são - o serviço sobe com um ambiente mínimo, então eles precisam ser adicionados à mão no arquivo gerado.

## Acesso ao painel

O painel web fica aberto em localhost por padrão, o que é conveniente para o desenvolvimento local. No momento em que você o expõe além da sua máquina, coloque-o atrás de uma senha:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Você pode passar uma senha literal ou uma referência `${ENV_VAR}` para que o segredo fique fora do arquivo. Uma vez definida a senha, o painel exige entrar em `/login`. Limpe-a com `pepe dashboard password --clear`.

A senha é lida de `dashboard.password` na configuração (interpolada), com um recuo para a variável de ambiente `PEPE_DASHBOARD_PASSWORD`. Dois ajustes relacionados reforçam um painel servido atrás de um domínio:

- `pepe dashboard hosts app.example.com,dash.example.com` define os valores extras do cabeçalho `Host` que o painel aceita. Isso serve também como a lista de permissão contra o reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista os proxies reversos cujo cabeçalho `X-Forwarded-For` pode ser considerado confiável. Vazio por padrão, o que significa que nenhum cabeçalho de encaminhamento é confiável.

Vinculado a uma interface pública sem senha, o painel se fecha por padrão e bloqueia clientes remotos até que você defina uma.
