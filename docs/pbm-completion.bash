#!/usr/bin/env bash
# pbm-completion.bash - Bash completion for pbm
#
# Installazione:
#   cp docs/pbm-completion.bash /etc/bash_completion.d/
#   source /etc/bash_completion.d/pbm-completion.bash
#
# Oppure nel tuo ~/.bashrc:
#   source /path/to/docs/pbm-completion.bash

_pbm() {
	local cur prev words cword
	_init_completion || return

	# Opzioni globali (si applicano a tutti i comandi)
	local global_opts="--host --port --print-curl --print-json --help -h"

	# Comandi disponibili
	local commands="ping status info list fetch update search clone"

	# URL git comuni per fetch
	local git_urls="https://github.com/"

	# Se è la prima parola dopo pbm, suggerisci i comandi
	if [[ ${#words[@]} -eq 1 ]] || [[ "${words[1]}" == -* ]]; then
		COMPREPLY=($(compgen -W "$global_opts $commands" -- "$cur"))
		return
	fi

	local cmd="${words[1]}"

	case "$cmd" in
	ping | status | update)
		# Non hanno argomenti
		;;
	info | list)
		# info può avere un nome pacchetto opzionale
		if [[ ${#words[@]} -eq 2 ]]; then
			# TODO: potremmo suggerire i pacchetti dal server
			COMPREPLY=($(compgen -W "" -- "$cur"))
		fi
		;;
	fetch)
		# Richiede un URL git
		if [[ ${#words[@]} -eq 2 ]]; then
			COMPREPLY=($(compgen -W "$git_urls" -- "$cur"))
		fi
		;;
	search)
		# Richiede una query
		if [[ ${#words[@]} -eq 2 ]]; then
			COMPREPLY=($(compgen -W "" -- "$cur"))
		fi
		;;
	clone)
		# Richiede un nome pacchetto
		if [[ ${#words[@]} -eq 2 ]]; then
			COMPREPLY=($(compgen -W "" -- "$cur"))
		fi
		;;
	esac

	# Completa per le opzioni globali
	if [[ "$cur" == -* ]]; then
		COMPREPLY+=($(compgen -W "$global_opts" -- "$cur"))
	fi
}

complete -F _pbm pbm
