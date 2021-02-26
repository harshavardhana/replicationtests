#!/bin/bash

WORK_DIR="$PWD"
DATA_DIR="$WORK_DIR/data"
DOWNLOAD_DIR="$WORK_DIR/download"

FILE_0_B="$DATA_DIR/0b"
FILE_1_MB="$DATA_DIR/1M"
FILE_129_MB="$DATA_DIR/129M"
declare FILE_0_B_MD5SUM
declare FILE_1_MB_MD5SUM
declare FILE_129_MB_MD5SUM

SOURCE_ALIAS="tsource"
DST_ALIAS="tdest"

function get_md5sum()
{
    filename="$1"
    out=$(md5sum "$filename" 2>/dev/null)
    rv=$?
    if [ "$rv" -eq 0 ]; then
        echo $(awk '{ print $1 }' <<< "$out")
    fi

    return "$rv"
}
function check_md5sum()
{
    expected_checksum="$1"
    shift
    filename="$@"

    checksum="$(get_md5sum "$filename")"
    rv=$?
    if [ "$rv" -ne 0 ]; then
        echo "unable to get md5sum for $filename"
        return "$rv"
    fi

    if [ "$checksum" != "$expected_checksum" ]; then
        echo "$filename: md5sum mismatch"
        return 1
    fi

    return 0
}
## Test successful replication of content and metadata for a small upload
function test_replicate_content()
{
    mc_cmd=(mc)
    BUCKET_NAME="bucket"
    object_name="repl-$RANDOM"

    mc cp --attr key1=val1\;key2=val2 "${1}" "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}"
    sleep 1m
    # Get source metadata and filter out metadata that is not useful to compare
    srcMeta=$(mc --json stat "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}" | jq 'del(.status,.expiration,.expires,.type)' --sort-keys)
    SRC_REPL_STATUS=$(echo "$srcMeta" | jq -r '.replicationStatus')
    if [ "$SRC_REPL_STATUS" != "COMPLETED" ]; then
        echo "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name} unexpected replication status :${SRC_REPL_STATUS}"
    else
        # remove replicationStatus from metadata
        srcMeta=$( echo $srcMeta | jq  'del(.replicationStatus)')
    fi

    vid=$(echo ${srcMeta}  |  jq -r '.versionID')
    # Get dest metadata for matching version and filter out metadata that is not useful to compare
    dstMeta=$(mc stat "${DST_ALIAS}/${BUCKET_NAME}/${object_name}" --vid ${vid} --json | jq 'del(.status,.expiration,.expires,.type)' --sort-keys)
    DST_REPL_STATUS=$(echo "$dstMeta" | jq -r '.replicationStatus')
    if [ "$DST_REPL_STATUS" != "REPLICA" ]; then
    echo "${DST_ALIAS}/${BUCKET_NAME}/${object_name} unexpected replication status :${DST_REPL_STATUS}"
    else
        # remove replicationStatus from metdata
        dstMeta=$( echo $dstMeta | jq  'del(.replicationStatus)')
    fi

    diff -bB <(echo ${srcMeta}) <(echo ${dstMeta})
    rc="$?"
    if [ "$rc" -ne 0 ]; then
        echo "Metadata difference for ${BUCKET_NAME}/${object_name}, ${srcMeta}, ${dstMeta}"
    fi
    
    #compare object data between replica and source
    mc cat "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}" >"$DOWNLOAD_DIR/${object_name}.downloaded.src"
    mc cat "${DST_ALIAS}/${BUCKET_NAME}/${object_name}" >"$DOWNLOAD_DIR/${object_name}.downloaded.dst"
    cmp --silent "$DOWNLOAD_DIR/${object_name}.downloaded.src" "$DOWNLOAD_DIR/${object_name}.downloaded.dst" || echo "replica and source data content differs"
    #clean up if compares ok
    if [ "$?" -eq 0 ]; then
        rm "$DOWNLOAD_DIR/${object_name}.downloaded.src"
        rm "$DOWNLOAD_DIR/${object_name}.downloaded.dst"
    fi
    #compare listing
    compare_listing ${BUCKET_NAME}/${object_name}
}

## Test successful replication of content and metadata for a small upload
function test_replicate_tags()
{
    mc_cmd=(mc)
    BUCKET_NAME="bucket"
    object_name="repl-$RANDOM"

    mc cp --attr key1=val1\;key2=val2 "${1}" "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}" >/dev/null 2>&1
     if [ "$?" -ne 0 ];then
       echo "cp failed on ${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}"
       return
    fi
    versionID=$(mc ls ${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name} --json --versions | jq -r .versionId )
    if [ "${versionID}" == "" ]; then
        echo "ls failed on ${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}"
        return
    fi
    # set tags on object
    mc tag set --version-id ${versionID} --json ${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name} "tagk1=tagv1&tagk2=tagv2"  >/dev/null 2>&1
    if [ "$?" -ne 0 ];then
       echo "could not set tags successfully"
       return
    fi
    # Get source metadata and filter out metadata that is not useful to compare
    srcMeta=$(mc --json stat "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name}" | jq 'del(.status,.expiration,.expires,.type)' --sort-keys)
    SRC_REPL_STATUS=$(echo "$srcMeta" | jq -r '.replicationStatus')
    if [ "$SRC_REPL_STATUS" != "COMPLETED" ]; then
        echo "${SOURCE_ALIAS}/${BUCKET_NAME}/${object_name} unexpected replication status :${SRC_REPL_STATUS}"
    else
        # remove replicationStatus from metadata
        srcMeta=$( echo $srcMeta | jq  'del(.replicationStatus)')
    fi

    vid=$(echo ${srcMeta}  |  jq -r '.versionID')
    # Get dest metadata for matching version and filter out metadata that is not useful to compare
    dstMeta=$(mc stat "${DST_ALIAS}/${BUCKET_NAME}/${object_name}" --vid ${vid} --json | jq 'del(.status,.expiration,.expires,.type)' --sort-keys)
    DST_REPL_STATUS=$(echo "$dstMeta" | jq -r '.replicationStatus')
    if [ "$DST_REPL_STATUS" != "REPLICA" ]; then
    echo "${DST_ALIAS}/${BUCKET_NAME}/${object_name} unexpected replication status :${DST_REPL_STATUS}"
    else
        # remove replicationStatus from metdata
        dstMeta=$( echo $dstMeta | jq  'del(.replicationStatus)')
    fi

    diff -bB <(echo ${srcMeta}) <(echo ${dstMeta})
    rc="$?"
    if [ "$rc" -ne 0 ]; then
        echo "Metadata difference for ${BUCKET_NAME}/${object_name}, ${srcMeta}, ${dstMeta}"
    fi
}


function compare_listing()
{
    diff -bB <(mc ls ${SOURCE_ALIAS}/${1} --json --versions --r | jq -r .key,.etag,.versionId ) <(mc ls ${DST_ALIAS}/${1} --json --versions --recursive | jq -r .key,.etag,.versionId ) >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "listing differs for ${1} between ${SOURCE_ALIAS} and ${DST_ALIAS}"
    fi
}
function run_test()
{
    # test single part upload
    #test_replicate_content ${FILE_1_MB}
    # test multi part upload
    #test_replicate_content ${FILE_129_MB}
    # test replication of tags set via PutObjectTagging API
    test_replicate_tags ${FILE_0_B}
    #test_replicate_copyobject ${FILE_0_B}
    
}
 
function __init__()
{
    set -e
    # Setup data dir
    # set mc binary - for now not needed
    # For Mint, setup is already done.  For others, setup the environment
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
    fi

    if [ ! -e "$FILE_0_B" ]; then
        base64 /dev/urandom | head -c 0 >"$FILE_0_B"
    fi

    if [ ! -e "$FILE_1_MB" ]; then
        base64 /dev/urandom | head -c 1048576 >"$FILE_1_MB"
    fi

    if [ ! -e "$FILE_129_MB" ]; then
        base64 /dev/urandom | head -c 135266304 >"$FILE_129_MB"
    fi

    if [ ! -d "$DOWNLOAD_DIR" ]; then
        mkdir -p $DOWNLOAD_DIR
    else 
        rm -rf $DOWNLOAD_DIR/*
    fi
    set -E
    set -o pipefail

    FILE_0_B_MD5SUM="$(get_md5sum "$FILE_0_B")"
    if [ $? -ne 0 ]; then
        echo "unable to get md5sum of $FILE_0_B"
        exit 1
    fi

    FILE_1_MB_MD5SUM="$(get_md5sum "$FILE_1_MB")"
    if [ $? -ne 0 ]; then
        echo "unable to get md5sum of $FILE_1_MB"
        exit 1
    fi

    FILE_129_MB_MD5SUM="$(get_md5sum "$FILE_129_MB")"
    if [ $? -ne 0 ]; then
        echo "unable to get md5sum of $FILE_129_MB"
        exit 1
    fi
    # assert_success "$start_time" "${FUNCNAME[0]}" mc_cmd alias set "${SERVER_ALIAS}" "$ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
    # assert_success "$start_time" "${FUNCNAME[0]}" mc_cmd alias set "${SERVER_ALIAS_TLS}" "$ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"

    set +e
}

function main()
{
    __init__
    ( run_test )
    rv=$?
    exit "$rv"
}

__init__ "$@"
main "$@"