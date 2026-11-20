# Default Linux task environment (design: section 5.4).
# Latest Ubuntu LTS. No agent harness is baked in: harnesses are opt-in and
# live in the per-user harness volume.
FROM ubuntu:26.04

ARG AGENT_UID=2000
ARG AGENT_GID=2000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      file \
      git \
      jq \
      less \
      openssh-client \
      python3 \
      python3-venv \
      ripgrep \
      sudo \
      tmux \
      unzip \
      wget \
      xz-utils \
      zip \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu images ship an `ubuntu` user; replace it with `agent`, matching the
# host's `clankstation` uid/gid. Agents get passwordless sudo inside the
# container (design: section 1).
RUN userdel --remove ubuntu 2>/dev/null || true \
 && groupadd --gid "${AGENT_GID}" agent \
 && useradd --uid "${AGENT_UID}" --gid agent --create-home --shell /bin/bash agent \
 && echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent \
 && chmod 0440 /etc/sudoers.d/agent \
 && mkdir -p /workspace \
 && chown agent:agent /workspace

USER agent
ENV PATH=/home/agent/.local/bin:${PATH}
WORKDIR /workspace

CMD ["sleep", "infinity"]
