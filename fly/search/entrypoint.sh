#!/bin/bash
# Root-side start-up for the staging search node (#364), then the image's own
# entrypoint as uid 1000. See the Dockerfile for why this exists.
set -euo pipefail

OPENSEARCH_HOME=/usr/share/opensearch
DATA_DIR="$OPENSEARCH_HOME/data"
WANTED_MAP_COUNT=262144

# A fresh volume's root directory is root:root 0755; OpenSearch (uid 1000)
# must be able to create nodes/ in it. Not recursive: the node creates
# everything below itself, and lost+found stays root's.
if [ "$(stat -c %u:%g "$DATA_DIR")" != "1000:1000" ]; then
  echo "cake-search: chown 1000:1000 $DATA_DIR (was $(stat -c %u:%g "$DATA_DIR"))"
  chown 1000:1000 "$DATA_DIR"
fi

# OpenSearch asks for vm.max_map_count >= 262144. Single-node discovery skips
# the bootstrap check, so a low value shows up later, as a failed mmap under
# load. Raise it when the kernel lets us and say so either way: this line in
# the machine's log is the record of what the host allowed.
current_map_count="$(cat /proc/sys/vm/max_map_count)"
if [ "$current_map_count" -lt "$WANTED_MAP_COUNT" ]; then
  if echo "$WANTED_MAP_COUNT" 2>/dev/null >/proc/sys/vm/max_map_count; then
    echo "cake-search: vm.max_map_count raised from $current_map_count to $WANTED_MAP_COUNT"
  else
    echo "cake-search: WARNING vm.max_map_count is $current_map_count and could not be raised"
  fi
else
  echo "cake-search: vm.max_map_count is $current_map_count"
fi

# The image has no su, runuser, setpriv or gosu; coreutils' chroot can change
# user without changing root.
export HOME="$OPENSEARCH_HOME"
cd "$OPENSEARCH_HOME"
exec chroot --userspec=1000:1000 --skip-chdir / ./opensearch-docker-entrypoint.sh "$@"
