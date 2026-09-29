#!/bin/bash
token="$1"
if [ ! -f build/step2_flag.txt ]; then
    touch build/step2_flag.txt
    echo "temporary failure in step 2" >&2
    exit 1
fi
echo "step2_success_with_${token}"
exit 0
