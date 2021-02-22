#!/bin/bash

docker-compose -f docker/docker-compose-2zones.yml down --remove-orphans
docker-compose -f docker/docker-compose-1zone.yml down --remove-orphans
docker stop $(docker ps -a -q) 
docker rm $(docker ps -a -q)
docker-compose -f docker/docker-compose-2zones.yml up -d
docker-compose -f docker/docker-compose-1zone.yml up -d

dstIP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'  docker-minioz14-dest)
echo "dstIP:{$dstIP}"
srcIP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'  docker-minioz21-src)
echo "srcIP:{$srcIP}"
echo 'http://{$srcIP}'
echo 'http://{$dstIP}'
mc alias remove tsource
mc alias remove tdest
mc alias set tsource 'http://{$srcIP}' minio minio123
mc alias set tdest 'http://{$dstIP}' minio minio123

# create buckets with versioning enabled
mc mb tsource/bucket --l 
mc mb tdest/bucket --l

#### Create a replication admin on tsource alias
# create a replication admin user : repladmin
mc admin user add tsource repladmin repladmin123

# create a replication policy for repladmin
cat > repladmin-policy-tsource.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
    {
        "Action": [
            "admin:SetBucketTarget",
            "admin:GetBucketTarget"
        ],
        "Effect": "Allow",
        "Sid": ""
     }, 
     {
      "Effect": "Allow",
      "Action": [
       "s3:GetReplicationConfiguration",
       "s3:ListBucket",
       "s3:ListBucketMultipartUploads",
       "s3:GetBucketLocation",
       "s3:GetBucketVersioning"
      ],
      "Retsource": [
       "arn:aws:s3:::bucket"
      ]
     }
    ]
   }
EOF
mc admin policy add tsource repladmin-policy ./repladmin-policy-tsource.json
cat ./repladmin-policy-tsource.json

#assign this replication policy to repladmin
mc admin policy set tsource repladmin-policy user=repladmin

### on tdest alias
# Create a replication user : repluser on tdest alias
mc admin user add tdest repluser repluser123

# create a replication policy for repluser
# Remove "s3:GetBucketObjectLockConfiguration" if object locking is not needed
# Remove "s3:ReplicateDelete" if delete marker replication is not required
cat > replpolicy.json <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Effect": "Allow",
   "Action": [
    "s3:GetReplicationConfiguration",
    "s3:ListBucket",
    "s3:ListBucketMultipartUploads",
    "s3:GetBucketLocation",
    "s3:GetBucketVersioning",
    "s3:GetBucketObjectLockConfiguration"
   ],
   "Retsource": [
    "arn:aws:s3:::bucket"
   ]
  },
  {
   "Effect": "Allow",
   "Action": [
    "s3:GetReplicationConfiguration",
    "s3:ReplicateTags",
    "s3:AbortMultipartUpload",
    "s3:GetObject",
    "s3:GetObjectVersion",
    "s3:GetObjectVersionTagging",
    "s3:PutObject",
    "s3:DeleteObject",
    "s3:ReplicateObject",
    "s3:ReplicateDelete"
   ],
   "Retsource": [
    "arn:aws:s3:::bucket/*"
   ]
  }
 ]
}
EOF
mc admin policy add tdest replpolicy ./replpolicy.json
cat ./replpolicy.json

#assign this replication policy to repluser
mc admin policy set tdest replpolicy user=repluser

# define remote target for replication from tsource/bucket -> tdest/bucket
replArn={mc admin bucket remote add repladminAlias/bucket http://repluser:repluser123@localhost:9000/bucket --service replication --region us-east-1 --json} | jq .RemoteARN

echo "Now, use this ARN to add replication rules using 'mc replicate add' command"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tsource/bucket --priority 1 --remote-bucket bucket --arn ${replArn} --replicate delete-marker,delete