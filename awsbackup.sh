#!/bin/bash

uploadDeep () {
    aws s3 cp $1 s3://$awsbucket/$jobname/ --storage-class DEEP_ARCHIVE
}
upload () {
    aws s3 cp $1 s3://$awsbucket/$jobname/
}

log () {
    echo "$(date "+%Y/%m/%d-%H:%M:%S") $1" >> backup.log
    echo "$1"
}

printusage () {
    echo "Usage: $0 [jobname] [keyfile] [tmpdir] [awsbucketname]"
}

# print help
if [ "$1" == "-h" ] || [ "$1" == "--help" ] || [ -z "$1" ]
then
   echo "-> Create and upload encrypted backups to AWS <-"
   printusage
   echo "Where"
   echo -e "\tjobname is the name to use for the archive"
   echo -e "\t\tfiles to backup are read from $(pwd)/jobname"
   echo -e "\tkeyfile contains the key to use for encryption"
   echo -e "\toutdir is the directory to store the archive to"
   echo -e "\tawsbucketname is the bucket name in aws to use"
   exit 0
fi
   
# check args
if [ -z "$1" ]; then
    echo "jobname not supplied"
    printusage
    exit 1
fi
if [ -z "$4" ]; then
    echo "AWS bucket name not supplied"
    printusage
    exit 1
fi
if [ ! -f "$2" ]; then
    echo "$2 is not a file."
    printusage
    exit 1
fi
if [ ! -d "$3" ]; then
    echo "$3 is not a directory."
    printusage
    exit 1
fi

# read file list to space separated
jobname=$1
files=`cat $jobname | tr "\n" " "`
keyfile=$2
awsbucket=$4

datetime=`date "+%Y%m%dT%H%M%SZ"`
tar="$3/$1-$datetime.tar.xz"
enctar="$3/$1-$datetime.tar.xz.enc"
listfile="$3/$1-$datetime.list"

log "Starting backup to AWS, jobname $jobname"
# create the archive
log "Backing up to $tar"
tar -Jcf $tar -C / $files

# create the file list
log "Generatiung file list $listfile"
tar -Jtvf $tar > $listfile

# encrypt the tar
log "Encrypting tar to $tar.enc"
openssl aes-256-cbc -salt -pbkdf2 -pass file:$keyfile -in $tar -out $enctar

# delete the tar
log "Deleting $tar"
rm $tar

log "Uploading $listfile to AWS"
upload $listfile
log "Uploading $enctar to AWS DEEP GLACIER"
uploadDeep $enctar

log "Deleting $listfile, $enctar"
rm $listfile $enctar



log "Done backing up to AWS"
exit 0
