#!/usr/bin/env bash
# pbm-completion.bash - Bash completion for pbm
#
# Installazione:
#   sudo cp contrib/pbm-completion.bash /etc/bash_completion.d/
#   source /etc/bash_completion.d/pbm-completion.bash

_pbm() {
	local cur words cword
	cur=${COMP_WORDS[COMP_CWORD]}
	words=("${COMP_WORDS[@]}")
	cword=$COMP_CWORD

	local global_opts="--host --port --print-curl --print-json --timeout --help -h"
	local commands="ping status info list fetch update search clone"

	if [[ $cword -eq 1 ]] || [[ "${words[1]}" == -* ]]; then
		COMPREPLY=($(compgen -W "$global_opts $commands" -- "$cur"))
		return
	fi

	local cmd="${words[1]}"

	case "$cmd" in
	ping|status|update)
		;;
	info|list)
		[[ $cword -eq 2 ]] && COMPREPLY=($(compgen -W "" -- "$cur"))
		;;
	fetch)
		[[ $cword -eq 2 ]] && COMPREPLY=($(compgen -W "https://github.com/" -- "$cur"))
		;;
	search|clone)
		[[ $cword -eq 2 ]] && COMPREPLY=($(compgen -W "" -- "$cur"))
		;;
	esac

	if [[ "$cur" == -* ]]; then
		COMPREPLY+=($(compgen -W "$global_opts" -- "$cur"))
	fi
}

complete -F _pbm pbm
