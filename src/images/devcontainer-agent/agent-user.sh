#!/bin/sh
# Runs as root while building the agent layer. Plain POSIX sh with awk and
# sed only (no shadow-utils), so it also works on Alpine/busybox images.
set -eu

u="${REMOTE_USER:-}"
[ "$u" = root ] && u=

uid_taken() { awk -F: -v id="$1" '$3 == id { f = 1 } END { exit !f }' /etc/passwd; }
gid_taken() { awk -F: -v id="$1" '$3 == id { f = 1 } END { exit !f }' /etc/group; }

if [ -n "$u" ] && grep -q "^$u:" /etc/passwd; then
  old_uid=$(awk -F: -v u="$u" '$1 == u { print $3 }' /etc/passwd)
  old_gid=$(awk -F: -v u="$u" '$1 == u { print $4 }' /etc/passwd)
  home=$(awk -F: -v u="$u" '$1 == u { print $6 }' /etc/passwd)
  if [ "$old_uid" != "$AGENT_UID" ]; then
    if uid_taken "$AGENT_UID"; then
      echo "agent-user: uid $AGENT_UID is already used in this image" >&2
      exit 1
    fi
    sed -i "s/^\($u:[^:]*\):$old_uid:$old_gid:/\1:$AGENT_UID:$AGENT_GID:/" /etc/passwd
    if [ "$old_gid" != "$AGENT_GID" ]; then
      gid_taken "$AGENT_GID" && { echo "agent-user: gid $AGENT_GID is already used" >&2; exit 1; }
      sed -i "s/^\([^:]*:[^:]*\):$old_gid:/\1:$AGENT_GID:/" /etc/group
    fi
    if [ -d "$home" ]; then chown -R "$AGENT_UID:$AGENT_GID" "$home"; fi
  fi
  echo "agent-user: $u is now uid $AGENT_UID"
else
  uid_taken "$AGENT_UID" && { echo "agent-user: uid $AGENT_UID is already used" >&2; exit 1; }
  gid_taken "$AGENT_GID" || echo "agent:x:$AGENT_GID:" >>/etc/group
  echo "agent:x:$AGENT_UID:$AGENT_GID:Clankstation agent:/home/agent:/bin/sh" >>/etc/passwd
  if [ -d /etc/sudoers.d ]; then
    echo 'agent ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/agent
    chmod 0440 /etc/sudoers.d/agent
  fi
  echo "agent-user: created agent (uid $AGENT_UID)"
fi

mkdir -p /home/agent /workspace
chown "$AGENT_UID:$AGENT_GID" /home/agent /workspace
