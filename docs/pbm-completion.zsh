#!/usr/bin/env zsh
# pbm-completion.zsh - Zsh completion for pbm
#
# Installazione:
#   cp docs/pbm-completion.zsh /usr/local/share/zsh/site-functions/_pbm
#   compinit
#
# Oppure nel tuo ~/.zshrc:
#   fpath=(/path/to/docs $fpath)
#   autoload -U compinit && compinit

_pbm() {
    local -a commands
    commands=(
        'ping:Check if the server is reachable'
        'status:Show server status'
        'info:Show service info or package details'
        'list:List available packages'
        'fetch:Mirror a Git repository on the server'
        'update:Sync local state with the package source'
        'search:Search packages by name'
        'clone:Git-clone a hosted package from the server'
    )

    local -a global_opts
    global_opts=(
        '--host:Server host (default: localhost)'
        '--port:Server port (default: 9122)'
        '--print-curl:Print the equivalent curl command'
        '--help:Show this help message'
        '-h:Show this help message'
    )

    _arguments -C \
        $global_opts \
        '1: :->command' \
        '*: :->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
        args)
            case $words[1] in
                fetch)
                    _arguments '1:git_url:->url'
                    ;;
                info|list|clone)
                    _arguments '1:package:()'
                    ;;
                search)
                    _arguments '1:query:()'
                    ;;
                ping|status|update)
                    ;;
            esac
            ;;
    esac
}

_pbm "$@"
