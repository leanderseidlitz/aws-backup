#!/bin/bash

set -e
set -o pipefail
set -u
umask 077

BASEDIR="$(dirname $0)"
source $BASEDIR/common/common.sh

# load config file
if [[ -f "$BASEDIR/config" ]]
then
    . "$BASEDIR/config"
else
    die "config file $BASEDIR/config missing"
fi

uploadClass () {
    aws s3 cp "$1" "s3://$awsbucket/$jobname/$2/" --storage-class "$3"
}
upload () {
    aws s3 cp "$1" "s3://$awsbucket/$jobname/$2/"
}

log () {
    echo "$(date "+%Y-%m-%dT%H:%M:%SZ") $1" >> "$BASEDIR/backup.log"
    einfo "$1"
}

cleanup () {
    if [[ -n "${jobdir:-''}" ]]
    then
	rm -r "$jobdir"
    fi
}

printusage () {
    echo "-> Create and upload encrypted backups to AWS <-"
    echo "Where"
    echo -e "\tjobname is the name to use for the archive"
    echo -e "\t-z: use zstd for tar"
    echo "Usage: $0 [jobname] [-z]"
    exit 0
}

checkkey () {
    if [[ ! -f "$pubkeyfile" ]]
    then
	log "Public keyfile ($pubkeyfile) missing"
	countdown "Generating new keys in " 5
	openssl genrsa -out "$BASEDIR"/aws.pem 4096
	openssl rsa -in "$BASEDIR"/aws.pem -outform PEM -pubout -out "$BASEDIR"/aws-public.pem
	echo "pubkeyfile=aws-public.pem" >> "$BASEDIR"/config
	log "RSA Keys generated, saved to aws.pem, aws-public.pem"
	log "You should backup the private key..."
    fi
}

zstd="false"
while getopts ":hz:" o; do
    case "$o" in
	h)  usage
	    ;;
	z)  zstd="true"
	    ;;
	*)  ;;
    esac
done
shift $((OPTIND-1))

jobname=$1
if [[ ! -f "$BASEDIR/jobs/$jobname" ]]
then
    error "job file $BASEDIR/jobs/$jobname is missing."
    die "action: create jobfile at $BASEDIR/jobs/$jobname"
fi

if [[ ! -d "$(dirname "$tmpdir")" ]]
then
    eerror "parent of tmpdir ($(dirname $tmpdir)) is missing."
    die "action: create dir, fix config"
fi
[[ -d "$tmpdir" ]] || mkdir -p "$tmpdir"

trap cleanup EXIT

# read file list to relative paths from /, space separated, escape spaces in filename
files=""
while read f
do
    files="$files $(realpath --relative-to=/ "$(echo "$f" | sed 's/ /\\ /g')")"
done < "$BASEDIR/jobs/$jobname"

log "Backing up $files"
# check that pubkey is present, otherwise generate
checkkey

# define filenames
datetime="$(date "+%Y%m%dT%H%M%SZ")"
jobdir="$tmpdir/$jobname-$datetime"
[[ -d "$jobdir" ]] || mkdir -p "$jobdir"
tarkey="$jobdir/$jobname-$datetime.tarkey"
listkey="$jobdir/$jobname-$datetime.listkey"
metakey="$jobdir/$jobname-$datetime.metakey"
if [ "$zstd" == "true" ]; then
    enctar="$jobdir/$jobname-$datetime.tar.zstd.aes"
    compopts="-I zstd"
else
    enctar="$jobdir/$jobname-$datetime.tar.aes"
    compopts=""
fi
enclist="$jobdir/$jobname-$datetime.list.aes"
meta="$jobdir/$jobname-$datetime.meta"
encmeta="$jobdir/$jobname-$datetime.meta.aes"

log "Starting backup to AWS, jobname $jobname"

log "Generating keys"
openssl rand -hex 64 > "$tarkey"
openssl rand -hex 64 > "$listkey"
openssl rand -hex 64 > "$metakey"

# create the archive and file list
log "Generating mtree file list $enclist"
bsdtar -C / -cf - --format=mtree --options='sha256' $files | openssl aes-256-ctr -salt -pbkdf2 -pass file:"$listkey" -out "$enclist"

log "Backing up to encrypted $enctar"
tar $compopts --warning=no-file-changed -cf - -C / $files | openssl aes-256-ctr -salt -pbkdf2 -pass file:"$tarkey" -out "$enctar"

log "Generating metafile"
cat > "$meta" <<EOF
BKP VERSION $(git -C "$BASEDIR" rev-parse HEAD || echo "not git versioned")
SHA256 LIST $(sha256sum $enclist)
SHA256 TAR  $(sha256sum $enctar)
TARKEY      $(cat $tarkey)
LISTKEY     $(cat $listkey)
EOF

log "Encrypting metafile"
openssl aes-256-ctr -salt -pbkdf2 -pass file:"$metakey" -out "$encmeta" < "$meta"
openssl rsautl -encrypt -pubin -inkey "$pubkeyfile" -in "$metakey" -out "$metakey.aenc"

# delete the tar
log "Deleting unencrypted keys, metafile"
shred -u "$tarkey" "$listkey" "$metakey" "$meta"

log "Uploading encrypted metakey $metakey.aenc to AWS"
upload "$metakey.aenc" "$datetime"
log "Uploading $encmeta to AWS"
upload "$encmeta" "$datetime"
log "Uploading $enclist to AWS"
upload "$enclist" "$datetime"
log "Uploading $enctar to AWS $storageclass"
uploadClass "$enctar" "$datetime" "$storageclass"

log "Deleting leftover files after upload"
rm -f "$encmeta" "$enclist" "$enctar"


log "Done backing up to AWS"
exit 0
