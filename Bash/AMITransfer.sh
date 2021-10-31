#!/bin/bash

# params: src profile, dest profile, region, ami-id, name

echo "Please remember to run this in a linux/Mac machine terminal. Git Bash fails. No more than 5 snapshot limit for AMI"

jq --version
if [[ $? == 0 ]]
    then
        echo "package present"
    else
        echo "Please install jq for bash"
        exit 30
fi



defaultkey=""
srcacctid=$(aws sts get-caller-identity --profile $1 | jq -r '.Account')
destacctid=$(aws sts get-caller-identity --profile $2 | jq -r '.Account')

# src: non-default key present?
srckmskeys=$(aws kms list-keys --profile $1 --region $3 | jq '.[]' | jq '.[].KeyId')
for key in $srckmskeys; do
    formatedkey=$(echo "$key" | sed -e 's/^"//' -e 's/"$//')
    details=$(aws kms describe-key --key-id $formatedkey  --profile $1 --region $3)
    description=$(echo $details | jq -r '.[].Description')
    if [[ $description == Default* ]]; then
        # echo $formatedkey
        defaultkey=$formatedkey
    fi
done


# echo $defaultkey


anydefaults="n"
image=$(aws ec2 describe-images --image-id $4 --profile $1 --region $3 | jq '.[]' )
devicenames=$(echo "$image" | jq '.[].BlockDeviceMappings' | jq '.[].DeviceName')
snapshots=$(echo "$image" | jq '.[].BlockDeviceMappings' | jq '.[].Ebs.SnapshotId')
virtualtype=$(aws ec2 describe-images --image-id $4 --profile $1 --region $3 | jq '.[]' | jq '.[].VirtualizationType' | sed "s/\"//g")
architecture=$(aws ec2 describe-images --image-id $4 --profile $1 --region $3 | jq '.[]' | jq '.[].Architecture' | sed "s/\"//g")

if [[ -z "$5" ]]
    then
        aminame=$(aws ec2 describe-images --image-id $4 --profile $1 --region $3 | jq '.[]' | jq '.[].Name' | sed "s/\"//g")
    else
        aminame=$(echo $5 | sed "s/\"//g")

fi

for snap in $snapshots; do

    details=$(aws ec2 describe-snapshots --filters Name=snapshot-id,Values=$snap --profile $1 --region $3 )
    isdefault=$(echo "$details " | jq '.[]' | jq '.[].KmsKeyId' | grep -i "$defaultkey")
    snapid=$(echo "$details" | jq '.[]' | jq '.[].SnapshotId')
    # echo "$details"
    # echo "$isdefault"
    # echo "$snap"

    if [[ -z $isdefault ]]
        then
            continue 
        else
            # echo "default"
            anydefaults="y"
    fi
done

# echo "$anydefaults"


    # copy the volumes and keep track of new volumes

# Might need to alter if there are permission errors
policy="
    {
    \"Version\": \"2012-10-17\",
    \"Id\": \"key-consolepolicy-3\",
    \"Statement\": [
        {
        \"Sid\": \"Enable IAM User Permissions\",
        \"Effect\": \"Allow\",
        \"Principal\": {
            \"AWS\": [
                \"arn:aws:iam::$srcacctid:root\"
            ]
        },
        \"Action\": \"kms:*\",
        \"Resource\": \"*\"
        },
        {
        \"Sid\": \"Allow use of the key\",
        \"Effect\": \"Allow\",
        \"Principal\": {
            \"AWS\": [
            \"arn:aws:iam::$destacctid:root\"
            ]
        },
        \"Action\": [
            \"kms:Encrypt\",
            \"kms:Decrypt\",
            \"kms:ReEncrypt*\",
            \"kms:GenerateDataKey*\",
            \"kms:DescribeKey\"
        ],
        \"Resource\": \"*\"
        },
        {
        \"Sid\": \"Allow attachment of persistent resources\",
        \"Effect\": \"Allow\",
        \"Principal\": {
            \"AWS\": [
            \"arn:aws:iam::$destacctid:root\"
            ]
        },
        \"Action\": [
            \"kms:CreateGrant\",
            \"kms:ListGrants\",
            \"kms:RevokeGrant\"
        ],
        \"Resource\": \"*\",
        \"Condition\": {
            \"Bool\": {
            \"kms:GrantIsForAWSResource\": \"true\"
            }
        }
        }
    ]
    }
"
echo "create new kms key"
keydetails=$(aws kms create-key --description "AMITransfer" --policy "$policy" --profile $1 --region $3)
sleep 10
copykey=$(echo "$keydetails" | jq '.[].KeyId' | sed "s/\"//g")


tmp=""
newsnapssrc=""
# copy the volumes
for snap in $snapshots; do
    echo "create new volumes"
    snap=$(echo $snap | sed "s/\"//g")
    # tmp+="$snap"$'\n'
    tmp+=$(aws ec2 copy-snapshot --profile $1 --region $3 --encrypted --kms-key-id $copykey --source-region $3 --source-snapshot-id $snap | jq '.SnapshotId')$'\n'
    
done
newsnapssrc=$(echo "${tmp%?}")
echo "$newsnapssrc"


#check to see if the volumes are finished creating
while :; do
    sleep 30 
    ready="y"
    for snap in $newsnapssrc; do
        status=$(aws ec2 describe-snapshots --filters Name=snapshot-id,Values=$snap --profile $1 --region $3 | jq '.[]' | jq '.[].State') 
        if [[ $status == *completed* ]]
            then
                echo "Completed" $snap
                continue
            else
                echo "Not ready" $snap
                ready="n"
        fi
    done
    if [[ $ready == "y" ]]
        then 
            break
        else 
            continue 
    fi
done

# Share snaps with dest account
for snap in $newsnapssrc; do
    snap=$(echo $snap | sed "s/\"//g")
    aws ec2 modify-snapshot-attribute --profile $1 --region $3 --snapshot-id $snap --attribute createVolumePermission --operation-type add --user-ids $destacctid
done

# dest: copy all volumes with own kms key
tmp=""
newsnapsdest=""
# copy the volumes
for snap in $newsnapssrc; do
    echo "create new volumes in dest"
    snap=$(echo $snap | sed "s/\"//g")
    echo "$snap"
    # tmp+="$snap"$'\n'
    # echo "debug: $2 $3 $snap"
    tmp+=$(aws ec2 copy-snapshot --profile $2 --region $3 --encrypted  --source-region $3 --source-snapshot-id $snap | jq '.SnapshotId')$'\n'
done
newsnapsdest=$(echo "${tmp%?}")

#check to see if the volumes are finished creating
while :; do
    sleep 30 
    ready="y"
    for snap in $newsnapsdest; do
        status=$(aws ec2 describe-snapshots --filters Name=snapshot-id,Values=$snap --profile $2 --region $3 | jq '.[]' | jq '.[].State') 
        if [[ $status == *completed* ]]
            then
                echo "Completed" $snap
            else
                echo "Not ready" $snap
                ready="n"
        fi
    done
    if [[ $ready == "y" ]]
        then 
            break
        else 
            continue 
    fi
done

# dest: make ami from snaps
format="{\"DeviceName\":\"<mount>\",\"Ebs\":{\"SnapshotId\":\"<snap>\"}}"

mapdetails="["
length=$(echo "$newsnapsdest" | wc -l)
for i in `seq 1 $length`;
    do
        if [[ $i == 1 ]]
            then
                echo ""
            else
                mapdetails+=","
        fi
       # get snap id and mount point
        snap=$(echo "$newsnapsdest" | sed -n "$i"p | sed "s/\"//g")
        mount=$(echo "$devicenames" | sed -n "$i"p | sed "s/\"//g")
        mapdetails+=$(echo "$format" | sed -e "s|<mount>|$mount|g" | sed -e "s|<snap>|$snap|g")

done
mapdetails+="]"
rootdevice=$(echo "$devicenames" | sed -n "1"p | sed "s/\"//g")

echo "debug: " "$aminame" "$architecture" "$virtualtype" "$rootdevice" 

aws --profile $2 --region $3 ec2 register-image --name "$aminame" --description "Transfered via Script" --architecture $architecture --virtualization-type $virtualtype --root-device-name $rootdevice --block-device-mappings "$mapdetails"


#remove the src copies, set the kms key to expire

# Delete new snaps
for snap in $newsnapssrc; do
    snap=$(echo $snap | sed "s/\"//g")
    aws ec2 delete-snapshot --profile $1 --region $3 --snapshot-id $snap
done

 aws kms --profile $1 --region $3 schedule-key-deletion --key-id $copykey


