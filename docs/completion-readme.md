# Completamento Terminale per pbm

## Bash

```bash
# Opzione 1: Installa globalmente
sudo cp docs/pbm-completion.bash /etc/bash_completion.d/

# Opzione 2: Source nel tuo ~/.bashrc
echo 'source /path/to/pbm/docs/pbm-completion.bash' >> ~/.bashrc
source ~/.bashrc
```

## Zsh

```zsh
# Opzione 1: Installa in site-functions
sudo cp docs/pbm-completion.zsh /usr/local/share/zsh/site-functions/_pbm

# Opzione 2: Aggiungi al fpath nel ~/.zshrc
echo 'fpath=(~/path/to/pbm/docs $fpath)' >> ~/.zshrc
echo 'autoload -U compinit && compinit' >> ~/.zshrc
source ~/.zshrc
```

## Verifica

```bash
pbm <Tab><Tab>    # Mostra i comandi disponibili
pbm f<Tab>        # Completa in "fetch"
pbm fetch <Tab>   # Suggerisce URL comuni
```
