#!/bin/bash
# remove old source and dest if any
sudo rm --recursive --force "/home/kp/repltest/1zone*"
sudo rm --recursive --force "/home/kp/repltest/2zone*"

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
mc alias remove asource
mc alias remove adest

mc alias remove tsource
mc alias remove tdest
echo " mc alias set asource ${SRC_EP} minio minio123"
mc alias set asource ${SRC_EP} minio minio123
echo "mc alias set adest ${DST_EP} minio minio123"
mc alias set adest ${DST_EP} minio minio123

# # create buckets with versioning enabled
mc mb asource/bucket --l 
mc mb adest/bucket --l
mc mb asource/olockbucket --l 
mc mb adest/olockbucket --l

### on tsource/tdest create repluser with both admin and replication permissions

# create a replication policy for repluser
# Remove "s3:GetBucketObjectLockConfiguration" if object locking is not needed
# Remove "s3:ReplicateDelete" if delete marker replication is not required
cat > ./policy/replpolicy.json <<EOF
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
    "s3:PutReplicationConfiguration",
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

# Create a replication user 
mc admin user add adest repluser repluser123
mc admin user add asource repluser repluser123

mc admin policy add asource replpolicy ./policy/replpolicy.json
mc admin policy add adest replpolicy ./policy/replpolicy.json

#assign this replication policy to repluser
mc admin policy set asource replpolicy user=repluser
mc admin policy set adest replpolicy user=repluser

mc alias set tsource ${SRC_EP} repluser repluser123
mc alias set tdest ${DST_EP} repluser repluser123

# set up remote replication config from  source -> dest
REPL_ARN=$(mc admin bucket remote ls tsource/bucket --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )
if [ "$REPL_ARN" != "" ]; then
    mc replicate rm --all --force tsource/bucket
    mc admin bucket remote rm tsource/bucket --arn ${REPL_ARN}
fi
REPL_ARN=$(mc admin bucket remote add tsource/bucket http://repluser:repluser123@${dstIP}:${DST_PORT}/bucket --service replication --region ${DST_REGION} --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )

echo "Now, use this ARN ${REPL_ARN} to add replication rules using 'mc replicate add' command"
echo "mc replicate add tsource/bucket --priority 1 --remote-bucket bucket --arn ${REPL_ARN} --replicate delete-marker,delete"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tsource/bucket --priority 1 --remote-bucket bucket --arn ${REPL_ARN} --replicate delete-marker,delete

REPL_ARN=$(mc admin bucket remote ls tsource/olockbucket --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )
if [ "$REPL_ARN" != "" ]; then
    mc replicate rm --all --force tsource/olockbucket
    mc admin bucket remote rm tsource/olockbucket --arn ${REPL_ARN}
    echo "removed old arn"
fi
REPL_ARN=$(mc admin bucket remote add tsource/olockbucket http://repluser:repluser123@${dstIP}:${DST_PORT}/olockbucket --service replication --region ${DST_REGION} --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )

echo "Now, use this ARN ${REPL_ARN} to add replication rules using 'mc replicate add' command"
echo "mc replicate add tsource/olockbucket --priority 1 --remote-bucket olockbucket --arn ${REPL_ARN} --replicate delete-marker,delete"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tsource/olockbucket --priority 1 --remote-bucket olockbucket --arn ${REPL_ARN} --replicate delete-marker,delete

# set up remote replication config from dest -> source
REPL_ARN=$(mc admin bucket remote ls tdest/bucket --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )
if [ "$REPL_ARN" != "" ]; then
    mc replicate rm --all --force tdest/bucket
    mc admin bucket remote rm tdest/bucket --arn ${REPL_ARN}
    echo "removed old arn"
fi
REPL_ARN=$(mc admin bucket remote add tdest/bucket http://repluser:repluser123@${srcIP}:${SRC_PORT}/bucket --service replication --region ${SRC_REGION} --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )

echo "Now, use this ARN ${REPL_ARN} to add replication rules using 'mc replicate add' command"
echo "mc replicate add tdest/bucket --priority 1 --remote-bucket bucket --arn ${REPL_ARN} --replicate delete-marker,delete"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tdest/bucket --priority 1 --remote-bucket bucket --arn ${REPL_ARN} --replicate delete-marker,delete

REPL_ARN=$(mc admin bucket remote ls tdest/olockbucket --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )
if [ "$REPL_ARN" != "" ]; then
    mc replicate rm --all --force tdest/olockbucket
    mc admin bucket remote rm tdest/olockbucket --arn ${REPL_ARN}
    echo "removed old arn"
fi
REPL_ARN=$(mc admin bucket remote add tdest/olockbucket http://repluser:repluser123@${srcIP}:${SRC_PORT}/olockbucket --service replication --region ${SRC_REGION} --json | jq .RemoteARN |  sed -e 's/^"//' -e 's/"$//' )

echo "Now, use this ARN ${REPL_ARN} to add replication rules using 'mc replicate add' command"
echo "mc replicate add tdest/olockbucket --priority 1 --remote-bucket olockbucket --arn ${REPL_ARN} --replicate delete-marker,delete"
# use arn returned by above command to create a replication policy on the tsource/bucket with `mc replicate add`
mc replicate add tdest/olockbucket --priority 1 --remote-bucket olockbucket --arn ${REPL_ARN} --replicate delete-marker,delete
