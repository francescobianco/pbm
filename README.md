# pbm - Packbase Manager

CLI client per gestire il server [packbase](https://github.com/yafb/packbase).

## Installazione

```bash
make build
make install
```

Oppure scarica il binary dalla [ releases page](https://github.com/yafb/pbm/releases).

## Quick Start

1. Avvia il server packbase con Docker:

```bash
docker run -p 9122:9122 -d yafb/packbase
```

2. Verifica lo stato del server:

```bash
pbm status
```

Output esempio:

```
service    packbase  (r0016)
healthy    14/85  (71 unhealthy)
disk       22% used

update     idle
packages   85 total  ·  85 probed  ·  1 synced
source     83 packages
tarballs   0 present  ·  91 created
repos      1 scanned
```

## Comandi

| Comando | Descrizione |
|---------|-------------|
| `pbm ping` | Verifica se il server è raggiungibile |
| `pbm status` | Mostra lo stato del server |
| `pbm info [package]` | Mostra info sul server o dettagli di un pacchetto |
| `pbm list` | Elenca tutti i pacchetti disponibili |
| `pbm search <query>` | Cerca pacchetti per nome |
| `pbm fetch <git_url>` | Aggiunge un nuovo pacchetto dal repository git |
| `pbm update` | Sincronizza lo stato locale con le sorgenti pacchetti |
| `pbm check <package>` | Verifica salute e metadati di un pacchetto |
| `pbm clone <package>` | Git-clone un pacchetto hosted |

## Opzioni Globali

| Opzione | Descrizione | Default |
|---------|-------------|---------|
| `--host <host>` | Server host | localhost |
| `--port <port>` | Server port | 9122 |
| `--print-json` | Stampa JSON raw dal server | - |
| `--print-curl` | Stampa il comando curl equivalente | - |
| `--timeout <sec>` | Timeout polling per update (default: 10) | 10 |

## Configurazione

Le opzioni sono lette in ordine di precedenza:
1. Flag `--host` / `--port`
2. Variabile `PACKBASE_URL` (es. `http://myserver:9122`)
3. File `.pbmrc` nella directory corrente
4. File `.pbmrc` nella home directory

Per l'autenticazione con `fetch`, usa la variabile `PACKBASE_TOKEN`.

## Esempi

```bash
# Verifica connessione
pbm ping

# Cerca pacchetti
pbm search zlib

# Aggiungi un pacchetto (richiede TOKEN)
PACKBASE_TOKEN=xxx pbm fetch https://github.com/example/package

# Aggiorna i dati (con polling)
pbm update --timeout 30

# Modalità curl per debug
pbm --print-curl status
```

## Completamento Shell

Bash:
```bash
make completion
# oppure manualmente
sudo cp contrib/pbm-completion.bash /etc/bash_completion.d/pbm
```

Zsh:
```bash
sudo cp contrib/pbm-completion.zsh /usr/share/zsh/site-functions/_pbm
```
