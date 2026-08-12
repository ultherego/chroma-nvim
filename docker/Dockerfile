# A machine to install Chroma onto, that is not anybody's machine.
#
# `chroma install` downloads plugins, fetches Mason packages and compiles
# treesitter parsers. Doing that on a development machine means a test that
# writes hundreds of megabytes into somebody's home directory and cannot be
# undone by deleting one thing — so it happens here instead, and `docker run
# --rm` is the cleanup.
#
# Deliberately Ubuntu rather than the maintainer's own distribution: a
# configuration that only installs on the machine it was written on is not
# installable. This also matches the CI runners, so a failure here and a failure
# there are the same failure.
#
#   docker build -t chroma-test docker/
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/dist/chroma:/usr/local/bin/chroma:ro" chroma-test \
#     chroma install --source-tree /src --components '' --yes
#
# The repository goes in read-only. Nothing the container does can reach back
# out, and nothing it leaves behind survives the run.
#
# The other use is reproducing CI's "Neovim starts clean" without waiting for a
# runner — the same Lazy sync, parser install, silent-startup and module-load
# checks against a chosen component profile. That one needs a **writable copy**
# of the tree inside the container:
#
#   tar -C /src --exclude=./.git -cf - . | tar -C "$HOME/chroma" -xf -
#
# not the read-only mount, because lazy.nvim writes `lazy-lock.json` while
# installing and fails with `E5108: … Read-only file system` before anything
# else has a chance to be wrong. It looks exactly like a startup regression and
# is not one. CI runs against a checkout it owns; the copy is that arrangement,
# and the host's working tree still stays untouched.
FROM ubuntu:24.04

# Versions are pinned and checked. Upstream publishes no checksums for either of
# these, so the sums below were computed from a download made on purpose — the
# same arrangement, and the same reasoning, as selene and actionlint in CI.
ARG NEOVIM_VERSION=v0.12.4
ARG NEOVIM_SHA256=012bf3fcac5ade43914df3f174668bf64d05e049a4f032a388c027b1ebd78628
ARG TREE_SITTER_VERSION=v0.26.9
ARG TREE_SITTER_SHA256=9ce82137caa65864e7ca8b869fd391cef88c9bd2a01c4371b9c4dd26c2585efb

ENV DEBIAN_FRONTEND=noninteractive

# What the component contract calls for, plus the runtimes Mason installs
# through. Several language servers are npm packages and several linters are
# Python ones, so node and pip are not optional extras here — without them the
# provisioning step would fail for reasons that have nothing to do with Chroma.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git tar gzip unzip xz-utils \
      build-essential \
      python3 python3-pip python3-venv \
      nodejs npm \
      ripgrep fd-find bat fzf \
      locales \
    && rm -rf /var/lib/apt/lists/*

# Debian names two of these differently from every other distribution, and the
# configuration looks for the names upstream uses. Without this, preflight
# reports them missing on a machine that has them.
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/batcat /usr/local/bin/bat

# A UTF-8 locale, because the dashboard and the statusline draw box characters
# and a C locale turns them into question marks — which looks like a font
# problem and is not one.
RUN sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN curl -fsSL -o /tmp/nvim.tar.gz \
      "https://github.com/neovim/neovim/releases/download/${NEOVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
    && echo "${NEOVIM_SHA256}  /tmp/nvim.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/nvim.tar.gz -C /opt \
    && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.tar.gz

# From the release rather than from npm, which upstream is explicit is not
# supported, and rather than from cargo, which would add a Rust toolchain and
# several minutes to every build of this image.
RUN curl -fsSL -o /tmp/tree-sitter.gz \
      "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-linux-x64.gz" \
    && echo "${TREE_SITTER_SHA256}  /tmp/tree-sitter.gz" | sha256sum -c - \
    && gunzip -c /tmp/tree-sitter.gz > /usr/local/bin/tree-sitter \
    && chmod +x /usr/local/bin/tree-sitter \
    && rm /tmp/tree-sitter.gz

# Not root. Mason and npm behave differently as root, and an installer that has
# only ever been run as root is an installer nobody has tested.
RUN useradd --create-home --shell /bin/bash tester
USER tester
WORKDIR /home/tester

# Everything Chroma writes goes under here, so a run leaves nothing anywhere
# else — and `--rm` leaves nothing at all.
ENV HOME=/home/tester

CMD ["bash"]
