#!/bin/bash

#Params: dns, <user>, <pem path>

downloadsPath=""
keysPath=""

if [ -z "$1" ]
then
echo "No AWS Instance DNS Supplied"
exit 1
fi

if [ -z "$2" ]; then
echo "Using 'ec2-user'"
user="ec2-user"
else
user="$2"
fi

if [ -z "$3" ]; then
echo "Looping .pem files"
path="$keysPath/*.pem $downloadsPath/*.pem"
else
path="$3"
fi

for f in $path; do

echo "Try: $f"
ssh -i "$f" $user@$1
if [ $? -eq 0 ]; then
exit 32
else
echo "Pass"
fi
done

echo "SSH Connection Failed"
