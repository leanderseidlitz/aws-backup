#!/bin/bash

elog() {
	echo "[[1m+[m] $*"
}

einfo() {
	echo "[[1;32m+[m] $*"
}

eattention() {
	echo "[[1;33m![m] $*"
}

ewarn() {
	echo "[[1;33m+[m] $*" >&2
}

eerror() {
	echo " [1;31m* ERROR:[m $*" >&2
}


die() {
	eerror "$*"
	exit 1
}

ok(){
        echo "[1;36m[[1;32m ok [1;36m][m $*"
}

countdown() {
	echo -n "$1" >&2

	local i="$2"
	while [[ $i -gt 0 ]]; do
		echo -n "[1;31m$i[m " >&2
		i=$((i - 1))
		sleep 1
	done
	echo >&2
}
