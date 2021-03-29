#!/bin/bash

set -e
set -o pipefail
set -u

BASEDIR="$(dirname $0)"
source $BASEDIR/common/common.sh

# load config file
if test -f $BASEDIR/config ; then
    . $BASEDIR/config
else
    die "config file $BASEDIR/config missing"
fi

uploadClass () {
    aws s3 cp $1 "s3://$awsbucket/$jobname/$2/" --storage-class $3
}
upload () {
    aws s3 cp $1 "s3://$awsbucket/$jobname/$2/"
}

log () {
    echo "$(date "+%Y-%m-%dT%H:%M:%SZ") $1" >> $BASEDIR/backup.log
    einfo "$1"
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
    if [ ! -f "$pubkeyfile" ]
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

if [ ! -d $(dirname "$tmpdir") ]
then
    eerror "parent of tmpdir ($(dirname $tmpdir)) is missing."
    die "action: create dir, fix config"
fi
if [ ! -d "$tmpdir" ]
then
    einfo "Creating tmpdir ($tmpdir)"
    mkdir "$tmpdir"
fi

jobname=$1
if [ ! -f "$BASEDIR/jobs/$jobname" ]; then
    error "job file $BASEDIR/jobs/$jobname is missing."
    die "action: create jobfile at $BASEDIR/jobs/$jobname"
fi

# read file list to relative paths from /, space separated, escape spaces in filename
files=""
while read f
do
    files="$files $(realpath --relative-to=/ "$(echo "$f" | sed 's/ /\\ /g')")"
done < $BASEDIR/jobs/$jobname

log "Backing up $files"
# check that pubkey is present, otherwise generate
checkkey

# define filenames
datetime=$(date "+%Y-%m-%dT%H:%M:%SZ")
tarkey="$tmpdir/$jobname-$datetime.tarkey"
listkey="$tmpdir/$jobname-$datetime.listkey"
if [ "$zstd" == "true" ]; then
    enctar="$tmpdir/$jobname-$datetime.tar.zstd.aes"
    compopts="-I zstd"
else
    enctar="$tmpdir/$jobname-$datetime.tar.aes"
    compopts=""
fi
enclist="$tmpdir/$jobname-$datetime.list.aes"
meta="$tmpdir/$jobname-$datetime.meta"
encmeta="$tmpdir/$jobname-$datetime.meta.aenc"

log "Starting backup to AWS, jobname $jobname"

log "Generating keys"
openssl rand -hex 16 > $tarkey
openssl rand -hex 16 > $listkey

# create the archive and file list
log "Generating mtree file list $enclist"
bsdtar -C / -cf - --format=mtree --options='sha256' $files | openssl aes-256-ctr -salt -pbkdf2 -pass file:$listkey -out $enclist

log "Backing up to encrypted $enctar"
tar $compopts --warning=no-file-changed -cf - -C / $files | pv -i 60 | openssl aes-256-ctr -salt -pbkdf2 -pass file:$tarkey -out $enctar

log "Generating metafile"
echo "SHA256 LIST $(sha256sum $enclist)" > $meta
echo "SHA256 TAR  $(sha256sum $enctar)" >> $meta
echo "TARKEY      $(cat $tarkey)" >> $meta
echo "LISTKEY     $(cat $listkey)" >> $meta

log "Encrypting metafile"
openssl rsautl -encrypt -pubin -inkey $pubkeyfile -in $meta -out $encmeta

# delete the tar
log "Deleting unencrypted keys, metafile"
rm $tarkey $listkey $meta

log "Uploading $encmeta to AWS"
upload $encmeta $datetime
log "Uploading $enclist to AWS"
upload $enclist $datetime
log "Uploading $enctar to AWS $storageclass"
uploadClass $enctar $datetime $storageclass

log "Deleting leftover files after upload"
rm $encmeta $enclist $enctar


log "Done backing up to AWS"
exit 0
