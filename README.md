# stackarr

Stack local de mídia com [Stackarr](https://stackarr.io) como orquestrador: 34
serviços Docker declarados em `docker-compose.yml`, organizados em 29 *profiles*.
O Stackarr gera o compose efetivo a partir desse arquivo, aplica o que está
habilitado e mantém as senhas em sincronia.

## Requisitos

- Docker com Compose v2
- `python3` com `PyYAML` (`pip install pyyaml`) — usado pelos dois scripts
- `openssl`, opcional, para gerar senhas

## Instalação

```bash
cp .env.example .env
```

As chaves de segredo do `.env` vêm **vazias** de propósito: o compose as marca
com `:?`, então ele recusa subir enquanto alguma estiver vazia. Preencha todas
antes de continuar.

```bash
./scripts/apply-admin-password.sh     # aplica as credenciais
docker compose --profile stackarr up -d
```

As portas ficam em `127.0.0.1` por padrão. O painel do Stackarr abre em
<http://127.0.0.1:7777>.

## Estrutura

| Caminho | Papel |
| --- | --- |
| `docker-compose.yml` | 34 serviços, 29 profiles. Única fonte do que o Stackarr implanta. |
| `.env` | Configuração local **com segredos**. Não versionado. |
| `.env.example` | Template sem segredos. É o que vai para o repo. |
| `scripts/apply-admin-password.sh` | Propaga `STACKARR_ADMIN_PASSWORD` para todos os serviços. |
| `scripts/apply-language-config.sh` | Aplica idioma de interface, metadados e legendas. |
| `.stackarr/` | Estado de execução: bancos, configs, logs, mídia. Não versionado (~566 MB). |

## Senhas

`apply-admin-password.sh` mantém a mesma senha no admin de:

Postgres · qBittorrent · Radarr · Sonarr · Lidarr · Prowlarr · Bazarr ·
tinyMediaManager · Stackarr

Cada serviço grava a senha no formato próprio — PBKDF2 nos *arr, PBKDF2-SHA512
com `@ByteArray(...)` no qBittorrent, MD5 no Bazarr, SCRAM-SHA-256 no Postgres
e **texto puro** no `stackarr.db`. O script implementa cada formato e verifica
o resultado depois de gravar.

```bash
./scripts/apply-admin-password.sh           # aplicar
./scripts/apply-admin-password.sh --check   # relatar, sem alterar
```

Fora do alcance: o Recyclarr não tem login admin e o Jellyfin usa PBKDF2 com
salt por usuário — esse último é definido à mão.

## Idioma

```bash
./scripts/apply-language-config.sh           # aplicar
./scripts/apply-language-config.sh --check   # relatar, sem alterar
```

`STACKARR_UI_LANGUAGE` e `STACKARR_CONTENT_LANGUAGE` controlam interface e
metadados; `STACKARR_SUBTITLES` define a ordem de preferência de legenda;
`STACKARR_AUDIO=original` mantém o áudio de origem e nunca força dublagem.

A interface do Radarr, Sonarr, Lidarr e Prowlarr **não** segue o `.env`. Cada
app guarda um índice no seu próprio enum, e esses valores diferem entre apps:

| App | Valor | Formato |
| --- | --- | --- |
| Radarr | `30` | índice |
| Sonarr | `33` | índice |
| Lidarr | `30` | índice |
| Prowlarr | `pt_BR` | culture string |

Radarr e Lidarr coincidem em 30 enquanto Sonarr exige 33, o que prova que o
valor não pode ser deduzido do nome do arquivo de localização. Estão fixos em
`scripts/apply-language-config.sh`, confirmados visualmente na UI de cada app.
Para corrigir: ajuste na UI do app, leia com
`SELECT Value FROM Config WHERE Key='uilanguage'`, e atualize a tabela.

## Segurança

- `.env` e `.stackarr/` estão no `.gitignore`. Um segredo enviado para um
  remoto permanece legível no histórico, mesmo depois de um commit que o
  remova.
- O compose não tem nenhuma senha como default. Todo segredo é `:?`, sem
  fallback — não existe valor no repositório que valha numa instalação nova.
- `STACKARR_BIND_IP=127.0.0.1` mantém o stack fora da rede. Vários serviços
  (Radarr, Sonarr, Prowlarr, qBittorrent, Sonarr4K) **não têm login por
  padrão**; expor em `0.0.0.0` os deixa abertos.
- A senha compartilhada entre nove serviços é ponto único de comprometimento:
  quem obtiver uma obtém todas. Aceitável numa LAN confiável; prefira senhas
  por serviço se for expor.

## Serviços implantados

Neste ambiente: `app`, `database`, `qbittorrent`, `prowlarr`, `sonarr`,
`radarr`, `lidarr`, `bazarr`, `tinymediamanager`, `jellyfin`, `recyclarr`,
`tidarr`, `flaresolverr`. Os demais profiles não estão habilitados.

Para ver o que um profile traz antes de ligar:

```bash
docker compose --profile romm config --services
```

## Problemas conhecidos

- `--check` do `apply-language-config.sh` reinicia Radarr, Sonarr, Lidarr e
  Prowlarr. Ele promete não alterar nada, mas chama `restart()` antes de
  decidir se há o que gravar. Nenhum dado muda; apenas o uptime dos containers.
- O `apply-language-config.sh` marca `en` como `unwanted` no Recyclarr sempre
  que `pt-BR` está em `STACKARR_SUBTITLES`, o que contraria o `.env`, que
  inclui `en` como fallback desejado.
- O manipulador do Jellyfin abre `jellyfin.db` sem checar se o arquivo existe;
  numa instalação sem o banco isso cria um arquivo vazio no disco.
