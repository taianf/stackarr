# AGENTS.md

Contexto para agentes e LLMs. Este arquivo responde a três perguntas: o que é
este repositório, o que não pode ser feito aqui, e como verificar uma alteração.

Configuração de um stack de mídia Docker orquestrado pelo Stackarr. Quatro
arquivos versionados, e só isso:

- `docker-compose.yml` — 34 serviços em 29 profiles
- `.env.example` — template de configuração, **sem segredos**
- `scripts/apply-admin-password.sh` — sincroniza credenciais entre serviços
- `scripts/apply-language-config.sh` — sincroniza idioma, legenda e áudio

O restante é gerado ou local: `.env` (com senhas) e `.stackarr/` (566 MB de
estado de execução). Nenhum dos dois entra no git.

## Regras invioláveis

**Nunca versione um segredo.** Segredo enviado para um remoto não é removível:
permanece no histórico para sempre, mesmo com um commit posterior que o apague.
Antes de `git add`, confira o staging:

```bash
git diff --cached | grep -nEi 'password|secret|token|api_?key' | grep -v '^\s*[0-9]*:+\s*#'
```

**Nunca coloque um segredo como default no compose.** Use `${VAR:?mensagem}`.
Um default vira um valor público que vale em qualquer instalação que copie o
arquivo. Esta regra já foi violada 14 vezes no arquivo original e corrigida.

**Placeholders de senha precisam ficar vazios.** `${VAR:?}` só acusa ausência
quando a variável não tem valor. Um `CHANGE_ME` preenchido passa na checagem e
sobe o stack com senha `CHANGE_ME`. Deixe vazio e comente o motivo.

**Pare o container antes de escrever no arquivo de config dele.** Radarr,
Sonarr, Lidarr, qBittorrent e o app do Stackarr reescrevem a config a partir da
memória ao encerrar e sobrescrevem a edição. Os dois scripts já fazem
stop → grava → start. Não quebre esse padrão.

**Restaure o dono do arquivo.** Containers rodam como root e gravam como root.
Use `reroot()` (os dois scripts já têm) depois de escrever em config ou banco.

## Decisões que parecem erradas, mas não são

**Os valores de idioma são uma tabela literal, não um valor derivado.**
Radarr `30`, Sonarr `33`, Lidarr `30`, Prowlarr `pt_BR`. Radarr e Lidarr
coincidem em 30 e Sonarr exige 33, então qualquer dedução a partir do nome do
arquivo em `Localization/Core` está errada — `pt` (30) e `pt_BR` (31) não são
o mesmo índice, e o índice é do enum interno de cada app. Para corrigir:
ajuste na UI do app, leia `SELECT Value FROM Config WHERE Key='uilanguage'`, e
atualize a tabela. Não "simplifique" a tabela para um valor derivado.

**A senha do Postgres não vem de `DATABASE_SUPERUSER_PASSWORD`.**
O volume do Postgres aceita `POSTGRES_PASSWORD` apenas no primeiro `initdb`; o
`apply-admin-password.sh` troca a senha de verdade com `ALTER ROLE`. Trocar a
variável no `.env` não muda a senha do banco existente — e quebrar a conexão,
porque o compose continuaria passando a senha antiga. Para trocar a senha do
Postgres, rode o script.

**O `.env` é reescrito pelo script.** `tinymediamanager()` usa
`set_env_value()` para gravar `TINYMEDIAMANAGER_PASSWORD` e recriar o
container. Editar essa chave à mão e recriar o container na sequência funciona
também; o script existe para não errar a ordem.

**A senha do Stackarr fica em texto puro.** Em
`stackarr.db → app_settings → "stackarr.runtimeConfig"`, comparada com
`timingSafeEqual` contra o valor submetido. **Não aplique hash.** O par
`usuario/senha` do template (`admin/CHANGE_ME`) não funciona numa instalação
nova, porque a imagem embute um hex aleatório de 40 caracteres nesse campo.

**A senha do Stackarr não responde à API.** A API do Stackarr exige token de
sessão, e o fluxo é PUT em `stackarr.runtimeConfig`. Não tente autenticar por
`/api/v3/auth/login` como nos *arr.

## Armadilhas já reexploradas (não repetir a investigação)

- **Os *arr não respondem à API deste ambiente.** Token do banco, header
  `ApiKey`, cookie `RadarrAuth`, `/api/v3/auth/login`, `X-XSRF-TOKEN` e
  requisição de dentro do container por localhost: tudo devolve `401`. Edite o
  banco diretamente — é o caminho confiável.
- **O idioma de UI do Jellyfin não vive em `system.xml`.** O boot remove
  `<Language>`. A preferência real de legenda e áudio por usuário está em
  `.stackarr/config/jellyfin/data/data/jellyfin.db`, tabela `Users`,
  colunas `SubtitleLanguagePreference` e `AudioLanguagePreference`.
- **A senha do qBittorrent é PBKDF2-HMAC-SHA512**, 100.000 iterações, saída de
  64 bytes, armazenada como
  `WebUI\Password_PBKDF2="@ByteArray(base64salt:base64hash)"`. O wrapper
  `@ByteArray(...)` é a serialização do `QByteArray` do Qt; sem ele o valor é
  ignorado em silêncio e o qBittorrent cai para uma senha temporária aleatória a
  cada boot.
- **O Postgres deste stack usa `trust` no `pg_hba.conf`.** Conectar e ver
  sucesso não prova nada sobre a senha. O script confere o verifier SCRAM em
  `pg_authid.rolpassword`, que é o único teste válido.
- **`docker compose up` às vezes deixa o container em `Created` e sai com 0.**
  Julgue o resultado inspecionando o container, nunca pelo código de saída.
  `recreate_and_wait()` faz exatamente isso, com 3 tentativas.
- **O `.env` é lido sem exportar lixo.** Os dois scripts usam
  `read_env()`, que extrai só a chave pedida via `sed`. Não troque por
  `source .env` nem por `set -a`.

## Verificação

Rode os dois em modo de leitura antes de qualquer modo de escrita:

```bash
./scripts/apply-admin-password.sh --check
./scripts/apply-language-config.sh --check
```

Ambos saem com `1` se algo divergir. Depois de mexer em `docker-compose.yml`:

```bash
python3 -c "import yaml;print(len(yaml.safe_load(open('docker-compose.yml'))['services']))"
docker compose --env-file .env config -q          # com o .env real: 0
docker compose --env-file .env.example config -q  # com o template: 1, e é o esperado
```

O template **precisa** falhar. Se ele passar, algum segredo tem valor default.

Ao final de qualquer trabalho, confira:

```bash
git status --short
git diff --cached --name-only | grep -E '^(\.env$|\.stackarr/)' && echo "FALHA"
```

## Estilo

- Comentário explica **por quê**, não o quê. Os dois scripts documentam o
  motivo de cada formato de hash e de cada armadilha; siga o mesmo nível.
- Não comente código óbvio. Um `# increment i` é ruído.
- Sem emojis. Sem numeração de etapas. Sem punto final em títulos de lista.
- Tabelas para comparação de valores; listas para sequências.
- Português no texto de saída ao usuário, inglês no identificador.
