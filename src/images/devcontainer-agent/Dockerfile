# Layer added on top of a project's devcontainer image (design: section 5.4).
# Makes the devcontainer's remoteUser (or a new `agent` user when it is root
# or unset) use the host clankstation uid/gid, the same idea as the
# devcontainers CLI's updateRemoteUserUID. Bind-mounted worktrees then keep one
# owner on both sides.
# clankctl always passes BASE; the default only keeps the build linter quiet.
ARG BASE=scratch
FROM ${BASE}

ARG REMOTE_USER=
ARG AGENT_UID=2000
ARG AGENT_GID=2000

USER root
COPY agent-user.sh /tmp/clank-agent-user.sh
RUN REMOTE_USER="${REMOTE_USER}" AGENT_UID="${AGENT_UID}" AGENT_GID="${AGENT_GID}" \
      sh /tmp/clank-agent-user.sh \
 && rm /tmp/clank-agent-user.sh
