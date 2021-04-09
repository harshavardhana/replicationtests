#!/bin/bash
# remove old source and dest if any
sudo rm --recursive --force "${HOME}/repltest/1zone*"
sudo rm --recursive --force "${HOME}/repltest/2zone*"

docker-compose -f docker/docker-compose-2zones.yml down --remove-orphans
docker-compose -f docker/docker-compose-1zone.yml down --remove-orphans
docker stop $(docker ps -a -q) 
docker rm $(docker ps -a -q)
docker-compose -f docker/docker-compose-2zones.yml up -d
docker-compose -f docker/docker-compose-1zone.yml up -d
sleep 1m
echo "slep...t"
dstIP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'  minioz14)
echo "dstIP:{$dstIP}"
srcIP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'  minioz21)
SRC_PORT="9000"
DST_PORT="9000"
SRC_REGION="us-west-2"
DST_REGION="us-west-1"
SRC_EP="http://${srcIP}:${SRC_PORT}"
DST_EP="http://${dstIP}:${DST_PORT}"
echo "${SRC_EP}"
echo "${DST_EP}"
mc alias remove tsource
mc alias remove tdest
echo " mc alias set tsource ${SRC_EP} minio minio123"
mc alias set tsource ${SRC_EP} minio minio123
echo "mc alias set tdest ${DST_EP} minio minio123"
mc alias set tdest ${DST_EP} minio minio123

# # create buckets with versioning enabled
mc mb tsource/bucket --l 
mc mb tdest/bucket --l
mc mb tsource/olockbucket --l 
mc mb tdest/olockbucket --l

#### Create a replication admin on tsource alias
# create a replication admin user : repladmin
mc admin user add tsource repladmin repladmin123

# create a replication policy for repladmin
cat > ./policy/repladmin-policy-tsource.json <<EOF
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
      "Resource": [
       "arn:aws:s3:::bucket",
       "arn:aws:s3:::olockbucket"

      ]
     }
    ]
   }
EOF

mc admin policy add tsource repladmin-policy ./policy/repladmin-policy-tsource.json
cat ./policy/repladmin-policy-tsource.json

#assign this replication policy to repladmin
mc admin policy set tsource repladmin-policy user=repladmin

### on tdest alias
# Create a replication user : repluser on tdest alias
mc admin user add tdest repluser repluser123

# create a replication policy for repluser
# Remove "s3:GetBucketObjectLockConfiguration" if object locking is not needed
# Remove "s3:ReplicateDelete" if delete marker replication is not required
cat > ./policy/replpolicy.json <<EOF
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
   "Resource": [
    "arn:aws:s3:::bucket",
    "arn:aws:s3:::olockbucket"
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
   "Resource": [
    "arn:aws:s3:::bucket/*",
    "arn:aws:s3:::olockbucket/*"
   ]
  },
  {
   "Effect": "Allow",
   "Action": [
    "s3:GetObjectRetention",
    "s3:PutObjectRetention",
    "s3:GetObjectLegalHold",
    "s3:PutObjectLegalHold"
   ],
   "Resource": [
    "arn:aws:s3:::olockbucket/*"
   ]
  }
 ]
}
EOF

mc admin policy add tdest replpolicy ./policy/replpolicy.json
cat ./policy/replpolicy.json

#assign this replication policy to repluser
mc admin policy set tdest replpolicy user=repluser

mc alias remove asource
# mc alias remove rdest
echo " mc alias set asource ${SRC_EP} repladmin repladmin123"
mc alias set asource ${SRC_EP} repladmin repladmin123
echo "mc alias set rdest ${DST_EP} repluser repluser123"
mc alias set rdest ${DST_EP} repluser repluser123
echo "using admin credentials needed on source for setting up targets with alias asource"
# define remote target for replication from asource/bucket -> rdest/bucket
echo "showing current state of admin target"
REPL_ARN=$(mc admin bucket remote ls asource/bucket --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )
if [ "$REPL_ARN" != "" ]; then
    mc replicate rm --all --force tsource/bucket
    mc admin bucket remote rm tsource/bucket --arn ${REPL_ARN}
    echo "removed old arn"
fi
REPL_ARN=$(mc admin bucket remote add asource/bucket http://repluser:repluser123@${dstIP}:${DST_PORT}/bucket --service replication --region ${DST_REGION} --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )

echo "Now, use this ARN ${REPL_ARN} to add replication rules using 'mc replicate add' command"
echo "mc replicate add tsource/bucket --priority 1 --remote-bucket bucket --arn ${REPL_ARN} --replicate delete-marker,delete"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tsource/bucket --priority 1 --remote-bucket bucket --arn ${REPL_ARN} --replicate delete-marker,delete

REPL_ARN=$(mc admin bucket remote ls asource/olockbucket --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )
if [ "$REPL_ARN" != "" ]; then
    mc replicate rm --all --force tsource/olockbucket
    mc admin bucket remote rm tsource/olockbucket --arn ${REPL_ARN}
    echo "removed old arn"
fi
REPL_ARN=$(mc admin bucket remote add asource/olockbucket http://repluser:repluser123@${dstIP}:${DST_PORT}/olockbucket --service replication --region ${DST_REGION} --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )

echo "Now, use this ARN ${REPL_ARN} to add replication rules using 'mc replicate add' command"
echo "mc replicate add tsource/olockbucket --priority 1 --remote-bucket olockbucket --arn ${REPL_ARN} --replicate delete-marker,delete"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tsource/olockbucket --priority 1 --remote-bucket olockbucket --arn ${REPL_ARN} --replicate delete-marker,delete
