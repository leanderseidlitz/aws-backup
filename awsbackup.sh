#!/bin/bash
BASEDIR=/home/acknexster/Dev_local/aws-backup

uploadClass () {
    aws s3 cp $1 s3://$awsbucket/$jobname/ --storage-class $2
}
upload () {
    aws s3 cp $1 s3://$awsbucket/$jobname/
}

log () {
    echo "$(date "+%Y/%m/%d-%H:%M:%S") $1" >> backup.log
    echo "$1"
}

printusage () {
    echo "Usage: $0 [jobname]"
}

# print help
if [ "$1" == "-h" ] || [ "$1" == "--help" ] || [ -z "$1" ]
then
   echo "-> Create and upload encrypted backups to AWS <-"
   printusage
   echo "Where"
   echo -e "\tjobname is the name to use for the archive"
   exit 0
fi
   
# check args
if [ -z "$1" ]; then
    echo "jobname not supplied"
    printusage
    exit 1
fi

jobname=$1
if [ ! -f "$BASEDIR/$jobname" ]; then
    echo "job file ($BASEDIR/$jobname) is missing."
    printusage
    exit 1
fi

# read file list to relative paths from /, space separated, escape spaces in filename
while read f
do
    files="$files $(realpath --relative-to=/ "$(echo "$f" | sed 's/ /\\ /g')")"
done < $BASEDIR/$jobname

# load config file
if test -f $BASEDIR/config ; then
    . $BASEDIR/config
else
    echo "config file ($BASEDIR/config) missing"
    exit 1
fi

datetime=`date "+%Y%m%dT%H%M%SZ"`
tarkey="$tmpdir/$jobname-$datetime.key"
enctarkey="$tmpdir/$jobname-$datetime.key.aenc"
tar="$tmpdir/$jobname-$datetime.tar.gz"
enctar="$tmpdir/$jobname-$datetime.tar.gz.senc"
listfile="$tmpdir/$jobname-$datetime.list"
enclistfile="$tmpdir/$jobname-$datetime.list.senc"

log "Starting backup to AWS, jobname $jobname"
# create the archive
log "Backing up to $tar"
tar -czf $tar -C / $files

# create the file list
log "Generating file list $listfile"
tar -tzvf $tar > $listfile

log "Generating key for tar and list"
dd if=/dev/urandom bs=128 count=1 status=none | base64 -w 0 > $tarkey

# encrypt the tar
log "Encrypting tar..."
openssl aes-256-cbc -salt -pbkdf2 -pass file:$tarkey -in $tar -out $enctar

# encrypt the list
log "Encrypting list..."
openssl aes-256-cbc -salt -pbkdf2 -pass file:$tarkey -in $listfile -out $enclistfile

# encrypt the tar
log "Encrypting key..."
openssl rsautl -encrypt -pubin -inkey $pubkeyfile -in $tarkey -out $enctarkey


# delete the tar
log "Deleting unencrypted tar, listfile and key"
rm $tar $tarkey $listfile

log "Uploading $enctarkey to AWS"
upload $enctarkey
log "Uploading $enclistfile to AWS"
upload $enclistfile
log "Uploading $enctar to AWS DEEP GLACIER"
uploadClass $enctar $storageclass

log "Deleting encrypted files after upload"
rm $enctarkey $enclistfile $enctar


log "Done backing up to AWS"
exit 0
