# Copyright (C) 2023 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script prepares the update to a new ktfmt version in a single git
# repository. This will create max 2 CLs:
#   1. One that regenerates the ktfmt_includes.txt with the current version
#      of ktfmt, so that all files already properly formatted are checked
#      and files that are not already formatted are ignored. If the file is
#      already up-to-date, then this CL won't be created.
#   2. One that reformats all files with the new version of ktfmt. This CL
#      won't be created if all files are already formatted.

# Stop the script at the first error.
set -e

# Stop the script if we try to access a variable that does not exist.
set -u

# Fail if we didn't pass the correct args.
[ $# -ne 3 ] && {
    echo "Usage: $0 build_tools_id relative/repo/path/ bug_id"
    echo "Example: prepare_upgrade.sh 8932651 frameworks/base/ 266197805"
    exit 1
}

build_id=$1
repo_relative_path=$2
bug_id=$3
repo_absolute_path="${ANDROID_BUILD_TOP}/$repo_relative_path"

echo "Preparing upgrade of ktfmt from build $build_id"

cd $repo_absolute_path

# Check that the ktfmt_update1 and ktfmt_update2 local branches don't exist yet.
existing_branches=$(git branch | grep 'ktfmt_update1\|ktfmt_update2' || echo "")
[[ ! -z "$existing_branches" ]] && {
    echo "Branches ktfmt_update1 or ktfmt_update2 already exist, you should delete them before running this script"
    exit 1
}

# Fail if the workspace is not clean.
git_status=$(git status --porcelain)
[[ ! -z "$git_status" ]] && {
    echo "The current repository contains uncommitted changes, please run this script in a clean workspace"
    exit 1
}

echo "Downloading ktfmt.jar from aosp-build-tools-release"
tmp=/tmp/ktfmt
mkdir -p $tmp
zip_path="$tmp/common.zip"
/google/data/ro/projects/android/fetch_artifact --branch aosp-build-tools-release --bid $build_id --target linux build-common-prebuilts.zip $zip_path
unzip -q -o -d $tmp $zip_path
new_jar="$tmp/framework/ktfmt.jar"
[ -r "$new_jar" ] || (echo "Error: $new_jar is not readable" && exit 1)
echo "Extracted jar in $new_jar"

# Find the ktfmt_includes.txt and the folders/files that were included file
includes_file=$(cat PREUPLOAD.cfg | grep ktfmt.py | sed 's/.*-i \(.*\) .*/\1/' | cut -c 14-)
includes_file=${includes_file#"$repo_relative_path"}
[ -r "$includes_file" ] || (echo "Error: $includes_file is not readable" && exit 1)
included_folders=$(cat ktfmt_includes.txt | grep + | cut -c 2- | tr '\n' ' ')

echo "Creating local branch ktfmt_update1"
repo start ktfmt_update1

echo "Updating $includes_file with the command: \$ANDROID_BUILD_TOP/external/ktfmt/generate_includes_file.py --output=$includes_file $included_folders"
$ANDROID_BUILD_TOP/external/ktfmt/generate_includes_file.py --output=$includes_file $included_folders

git_status=$(git status --porcelain)
if [[ ! -z "$git_status" ]]
then
    echo "Creating first CL with update of $includes_file"

    # Use the sha1 of the jar file for change ID.
    change_id="I$(sha1sum $new_jar | sed 's/\([a-z0-9]\{40\}\) .*/\1/')"
    cl_message=$(cat << EOF
Regenerate include file for ktfmt upgrade

This CL was generated automatically from the following command:

$ $0 $@

This CL regenerates the inclusion file with the current version of ktfmt
so that it is up-to-date with files currently formatted or ignored by
ktfmt.

Bug: $bug_id
Test: Presubmits
Change-Id: $change_id
Merged-In: $change_id
EOF
)
    git add --all
    git commit -m "$cl_message"
else
    echo "No change were made to $includes_file, skipping first CL"
fi

echo "Creating local branch ktfmt_update2"
repo start --head ktfmt_update2

echo "Formatting the files that are already formatted with the command: \${ANDROID_BUILD_TOP}/external/ktfmt/ktfmt.py -i $includes_file --jar $new_jar $included_folders"
${ANDROID_BUILD_TOP}/external/ktfmt/ktfmt.py -i $includes_file --jar $new_jar $included_folders 2> /dev/null

git_status=$(git status --porcelain)
if [[ ! -z "$git_status" ]]
then
    echo "Creating second CL that format all files"

    # Use the sha1 of the jar file + some random salt for change ID.
    jar_copy=/tmp/ktfmt/copy.jar
    cp $new_jar $jar_copy
    echo "ktfmt_update" >> $jar_copy
    change_id="I$(sha1sum $jar_copy | sed 's/\([a-z0-9]\{40\}\) .*/\1/')"
    cl_message=$(cat << EOF
Format files with the upcoming version of ktfmt

This CL was generated automatically from the following command:

$ $0 $@

This CL formats all files already correctly formatted with the upcoming
version of ktfmt.

Bug: $bug_id
Test: Presubmits
Change-Id: $change_id
Merged-In: $change_id
EOF
)
    git add --all
    git commit -m "$cl_message"
else
    echo "All files were already properly formatted, skipping second CL"
fi

echo
echo "Done. You can now submit the generated CL(s), if any."
