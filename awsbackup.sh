#!/bin/bash

BASEDIR="$(dirname $0)"
source $BASEDIR/common/common.sh

set -e
set -o pipefail
set -u

# load config file
if test -f $BASEDIR/config ; then
    . $BASEDIR/config
else
    die "config file $BASEDIR/config missing"
fi

uploadClass () {
    aws s3 cp $1 s3://$awsbucket/$jobname/ --storage-class $2
}
upload () {
    aws s3 cp $1 s3://$awsbucket/$jobname/
}

log () {
    echo "$(date "+%Y/%m/%d-%H:%M:%S") $1" >> $BASEDIR/backup.log
    einfo "$1"
}

printusage () {
    echo "Usage: $0 [jobname] [-z]"
}

# print help
if [ "$1" == "-h" ] || [ "$1" == "--help" ] || [ -z "$1" ]
then
   echo "-> Create and upload encrypted backups to AWS <-"
   printusage
   echo "Where"
   echo -e "\tjobname is the name to use for the archive"
   echo -e "\t-z: use zstd for tar"
   exit 0
fi

zstd="false"
if [ "$#" -gt 1 ] && [ "$2" = "-z" ]; then
    zstd="true"
fi

jobname=$1
if [ ! -f "$BASEDIR/jobs/$jobname" ]; then
    echo "job file $BASEDIR/jobs/$jobname is missing."
    printusage
    exit 1
fi

# create tmpdir if missing
if [ ! -d "$tmpdir" ]
then
    mkdir -p "$tmpdir"
fi

# read file list to relative paths from /, space separated, escape spaces in filename
files=""
while read f
do
    files="$files $(realpath --relative-to=/ "$(echo "$f" | sed 's/ /\\ /g')")"
done < $BASEDIR/jobs/$jobname

log "Backing up $files"

# define filenames
datetime=`date "+%Y%m%dT%H%M%SZ"`
tarkey="$tmpdir/$jobname-$datetime.key"
enctarkey="$tmpdir/$jobname-$datetime.key.aenc"
if [ "$zstd" == "true" ]; then
    enctar="$tmpdir/$jobname-$datetime.tar.zstd.senc"
else
    enctar="$tmpdir/$jobname-$datetime.tar.senc"
fi
listfile="$tmpdir/$jobname-$datetime.list"
enclistfile="$tmpdir/$jobname-$datetime.list.senc"

log "Generating key for tar and list"
dd if=/dev/urandom bs=128 count=1 status=none | base64 -w 0 > $tarkey

log "Starting backup to AWS, jobname $jobname"
# create the archive and file list
if [ "$zstd" = "true" ]; then
    log "Generating mtree file list $listfile"
    bsdtar -C / -cf $listfile --format=mtree --options='sha256' $files
    log "Backing up to encrypted zstd compressed $enctar"
    tar -I zstd -cf - -C / $files | pv -i 60 | openssl aes-256-ctr -salt -pbkdf2 -pass file:$tarkey -out $enctar
else
    log "Generating mtree file list $listfile"
    bsdtar -C / -cf $listfile --format=mtree --options='sha256' $files
    log "Backing up to encrypted $enctar"
    tar -cf - -C / $files | pv -i 60 | openssl aes-256-ctr -salt -pbkdf2 -pass file:$tarkey -out $enctar
fi

# encrypt the list
log "Encrypting list..."
openssl aes-256-ctr -salt -pbkdf2 -pass file:$tarkey -in $listfile -out $enclistfile

# encrypt the tar
log "Encrypting key..."
openssl rsautl -encrypt -pubin -inkey $pubkeyfile -in $tarkey -out $enctarkey


# delete the tar
log "Deleting unencrypted listfile and key"
rm $tarkey $listfile

log "Uploading $enctarkey to AWS"
upload $enctarkey
log "Uploading $enclistfile to AWS"
upload $enclistfile
log "Uploading $enctar to AWS $storageclass"
uploadClass $enctar $storageclass

log "Deleting encrypted files after upload"
rm $enctarkey $enclistfile $enctar


log "Done backing up to AWS"
exit 0
