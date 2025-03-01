#!/bin/bash

# Scratch-build components in a side-tag
set -e

# tools
rhpkg=fedpkg
brew=koji

if [ $# -ne 2 ]; then
    echo "Manually running scratch-build test..."
    echo "----------------------------------------------------------------"
    read -p "Comma separated NVRs (e.g. gcc-11.2.1-6.1.el9) : " nvrs
    read -p "target release (e.g. rhel-9.0.0) : " release
else
    set -x

    # Parameters:
    # $1 - NVR
    # $2 - target release, e.g.: 'f34'
    nvrs=${1}
    release=${2}

    # Required environment variables:
    # KOJI_KEYTAB - path to the keytab that can be used to build packages in Koji
    # KRB_PRINCIPAL - kerberos principal
    # DIST_GIT_URL - dist-git URL
    # ARCH_OVERRIDE - (optional) only build for specified architectures (example: "x86_64,i686")
    # env | sort

    if [ -z "${KOJI_KEYTAB}" ]; then
        echo "Missing keytab, cannot continue..."
        exit 101
    fi

    if [ -z "${KRB_PRINCIPAL}" ]; then
        echo "Missing kerberos principal, cannot continue..."
        exit 101
    fi

    kinit -k -t ${KOJI_KEYTAB} ${KRB_PRINCIPAL}
fi

# identify the worker
# echo "----------------------------------------------------------------"
# cat /etc/*-release
# rpm -qf `which ${rhpkg}`
# echo "----------------------------------------------------------------"

set -x

# components under rebuild test
if [[ ${nvrs} == *systemtap* ]]; then
    # Skip building qemu, since it builds too long for a gating test
    components="glibc"
elif [[ ${nvrs} == *redhat-rpm-config* ]]; then
    components="zlib"
else
    # Skip building strace temporarily because of
    # https://bugzilla.redhat.com/show_bug.cgi?id=1929836
    components="kernel lua opencryptoki"
fi

# create a new side-tag
build_target="${release}-build"
sidetag_name=$(${rhpkg} request-side-tag --base-tag ${build_target} | grep ' created.$' | awk -F\' '{ print $2 }')
date

# tag the given NVR into the side-tag
for nvr in ${nvrs//,/\ }; do
    ${brew} tag ${sidetag_name} ${nvr}
done
date

# wait for repo regeneration
for nvr in ${nvrs//,/\ }; do
    ${brew} wait-repo --build ${nvr} ${sidetag_name} || \
    ${brew} wait-repo --build ${nvr} ${sidetag_name}
done
date

# scratch-build dependent component(s)
buildlogs=""
for component in ${components}; do
    export buildlog=$(mktemp buildlog.${component}.XXXXXXXXXX)
    buildlogs="${buildlogs} ${buildlog}"
    ( ./worker.sh ${component} ${release} ${sidetag_name} |& tee ${buildlog} ) &
    unset buildlog
done
wait
date

exit_code=$(awk -f parse.awk ${buildlogs})

# try to remove the side-tag as it is no longer needed
${rhpkg} remove-side-tag ${sidetag_name} ||:

set +x

# show the buildsystem task URLs
echo "Test results for ${nvrs} ${release}"
echo "----------------------------------------------------------------"
fgrep 'https:'  ${buildlogs}
echo "----------------------------------------------------------------"

# clean up
rm ${buildlogs}

exit ${exit_code}

