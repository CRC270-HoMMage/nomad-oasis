# syntax=docker/dockerfile:1

# Comments are provided throughout this file to help you get started.
# If you need more help, visit the Dockerfile reference guide at
# https://docs.docker.com/engine/reference/builder/

ARG PYTHON_VERSION=3.12
ARG UV_VERSION=0.7
ARG JUPYTER_VERSION=2026-08-03

# GPU-enabled Jupyter base for NORTH -- see the GPU-NORTH deployment runbook, Phase 2. That
# document is kept OUT of this public repo (it describes live host topology); ask the maintainer.
# MUST be declared here: an ARG used in a FROM line has to be in the global scope, i.e.
# before the first FROM. Declared after a FROM it belongs to that build stage and would
# expand to empty in a later FROM.
#
# Pinned by DIGEST, not tag, for REPRODUCIBILITY: a moving tag makes rebuilds
# non-deterministic and couples them to upstream's release schedule.
#
# ⚠️ Do NOT reinstate the older rationale that this pin guards against CUDA 13. That was written
# when the GPU host ran driver 535.309.01 (CUDA 12.4 ceiling). It now runs 580.173.02 (CUDA 13.0),
# and quay.io/jupyter publishes a `cuda13-` variant that would initialise fine. Staying on cuda12
# is a conservative default, not a constraint -- moving to cuda13 is a deliberate change worth
# verifying on its own rather than smuggling into a date bump.
#
# This digest is quay.io/jupyter/pytorch-notebook:cuda12-2026-08-03 -- deliberately the SAME DATE
# as JUPYTER_VERSION above, so the CPU and GPU images share a Jupyter base.
#
# ⚠️ BUMP BOTH TOGETHER. To resolve the digest for a new date:
#   curl -s 'https://quay.io/api/v1/repository/jupyter/pytorch-notebook/tag/?onlyActiveTags=true&specificTag=cuda12-<DATE>' \
#     | python3 -c 'import json,sys; print(json.load(sys.stdin)["tags"][0]["manifest_digest"])'
ARG JUPYTER_GPU_IMAGE=quay.io/jupyter/pytorch-notebook@sha256:69c72823a4e0dbee17114bbe44d0377bc9a39504a76f6314995f7d5bfaa98d60

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv_image

FROM python:${PYTHON_VERSION}-slim AS base

# Keeps Python from buffering stdout and stderr to avoid situations where
# the application crashes without emitting any logs due to buffering.
ENV PYTHONUNBUFFERED=1
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    UV_LINK_MODE=copy \
    UV_FROZEN=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv

# Create a non-privileged user.
# See https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user
ARG UID=1000
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    nomad


# Final stage to create the runnable image with minimal size
FROM base AS base_final

WORKDIR /app

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
       libgomp1 \
       libmagic1 \
       curl \
       zip \
       unzip \
       # clean cache and logs
       && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Activate the virtualenv in the container
# See here for more information:
# https://pythonspeed.com/articles/multi-stage-docker-python/
ENV PATH="/opt/venv/bin:$PATH"


FROM base AS builder

# Prevents Python from writing pyc files.
ENV PYTHONDONTWRITEBYTECODE=1

ENV RUNTIME=docker

WORKDIR /app

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      gcc \
      build-essential \
      curl \
      zip \
      unzip \
      git \
 && rm -rf /var/lib/apt/lists/*

# Install UV
COPY --from=uv_image /uv /bin/uv

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=source=.git,target=.git,type=bind \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --extra plugins


COPY scripts ./scripts

FROM builder AS docs

WORKDIR /app

ARG NOMAD_DOCS_REPO="https://github.com/FAIRmat-NFDI/nomad-docs.git"
ARG NOMAD_DOCS_REPO_REF=""

# Clones the documentation repository, checks out the version matching nomad-lab
# (unless a specific NOMAD_DOCS_REPO_REF is provided), installs it, and builds the documentation.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    set -ex && \
    # Clone the documentation repository \
    echo "Cloning from: ${NOMAD_DOCS_REPO}" && \
    git clone "${NOMAD_DOCS_REPO}" docs_repo && cd docs_repo && \
    # Determine which version to build \
    if [ -n "${NOMAD_DOCS_REPO_REF}" ]; then \
        # Use explicitly provided ref \
        echo "Checking out provided ref: ${NOMAD_DOCS_REPO_REF}"; \
        git checkout "${NOMAD_DOCS_REPO_REF}"; \
    else \
        # Match documentation version to nomad-lab version \
        NOMAD_VERSION=$(uv tree --package nomad-lab | grep "^nomad-lab v" | sed 's/^nomad-lab //'); \
        echo "Detected nomad-lab version: ${NOMAD_VERSION}"; \
        if git rev-parse --verify "refs/tags/${NOMAD_VERSION}" >/dev/null 2>&1; then \
            echo "Tag ${NOMAD_VERSION} found. Checking out."; \
            git checkout "${NOMAD_VERSION}"; \
        else \
            echo "Tag ${NOMAD_VERSION} not found. Checking out main branch."; \
            git checkout main; \
        fi; \
    fi && \
    # Install and build documentation \
    uv pip install . && \
    PYTHONPATH=src uv run --no-sync mkdocs build && \
    # Move built site to final destination \
    mkdir -p /app/built_docs && \
    cp -r site/* /app/built_docs

FROM builder AS gpu_action_builder

WORKDIR /app

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --extra plugins --extra gpu-action

FROM builder AS cpu_action_builder

WORKDIR /app

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --extra plugins --extra cpu-action

FROM base_final AS final

ARG PYTHON_VERSION=3.12

COPY --chown=nomad:${UID} --from=builder /opt/venv /opt/venv
COPY configs/nomad.yaml nomad.yaml
COPY pyproject.toml uv.lock /opt/
COPY --chown=nomad:${UID} --from=docs /app/built_docs /opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/app/static/docs

RUN mkdir -p /app/.volumes/fs \
 && chown -R nomad:${UID} /app \
 && chown -R nomad:${UID} /opt/venv \
 && mkdir nomad \
 && cp /opt/venv/lib/python${PYTHON_VERSION}/site-packages/nomad/jupyterhub_config.py nomad/


USER nomad

# The application ports
EXPOSE 8000
EXPOSE 9000

VOLUME /app/.volumes/fs

FROM final AS cpu_action_final

COPY --chown=nomad:${UID} --from=cpu_action_builder /opt/venv /opt/venv

FROM final AS gpu_action_final

COPY --chown=nomad:${UID} --from=gpu_action_builder /opt/venv /opt/venv


FROM quay.io/jupyter/base-notebook:${JUPYTER_VERSION} AS jupyter_builder

ENV UV_PROJECT_ENVIRONMENT=/opt/conda \
    UV_FROZEN=1

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      gcc \
      build-essential \
      curl \
      zip \
      unzip \
      git \
      # clean cache and logs
      && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}
WORKDIR "${HOME}"

COPY --from=uv_image /uv /bin/uv

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    # Use inexact to avoid removing pre-installed packages in the environment
    # Use no-install-project to skip installing the current project (`nomad-distribution`)
    uv sync --extra plugins --extra jupyter --no-install-project --inexact


FROM quay.io/jupyter/base-notebook:${JUPYTER_VERSION} AS jupyter
# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      curl \
      zip \
      unzip \
      git \
      # `nbconvert` dependencies
      # https://nbconvert.readthedocs.io/en/latest/install.html#installing-tex
      texlive-xetex \
      texlive-fonts-recommended \
      texlive-plain-generic \
      # clean cache and logs
      && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}
WORKDIR "${HOME}"

COPY --from=uv_image /uv /bin/uv

# ⚠️ THE SECOND ORPHANING POINT, and the one that actually bites. This stage starts FROM the
# same base image as its builder, so it holds its OWN copy of the base's alembic -- and `COPY`
# MERGES into an existing directory, it never replaces it. The builder's clean tree therefore
# lands on top of that copy and the orphaned files come straight back, so cleaning only the
# builder achieves nothing.
#
# CI proved this on 2026-08-11: the builder step logged a clean
#     Uninstalled 1 package  - alembic==1.18.5
#     + alembic==1.16.5
# and the very next step -- `COPY --from=jupyter_builder /opt/conda /opt/conda` -- brought the
# collision back, failing the smoke test below. Remove the base's copy BEFORE the merge.
#
# Both bases ship alembic (base-notebook AND pytorch-notebook, 2026-08-03), so both final
# stages need this. If a future base collides on some other package, the smoke test is what
# will tell you -- add it here as well rather than restructuring the COPY.
RUN uv pip uninstall --python /opt/conda/bin/python alembic
COPY --from=jupyter_builder /opt/conda /opt/conda

# ⚠️ SMOKE TEST — do not remove. `start-notebook.py` branches on the JUPYTERHUB_* env: run
# standalone it execs `jupyter lab`, which never imports jupyterhub; spawned by the hub it
# execs `jupyterhub-singleuser`, which does. Only NORTH takes the second path, so a broken
# singleuser is completely invisible to `docker run <image>` (it starts JupyterLab and looks
# healthy) and shows up only as a session that starts, exits, and leaves the hub timing out
# 300s later. Failing the build is the only cheap place to catch it.
RUN python -c "import jupyterhub.singleuser" \
 && jupyterhub-singleuser --version


# Get rid ot the following message when you open a terminal in jupyterlab:
# groups: cannot find name for group ID 11320
RUN touch ${HOME}/.hushlogin


# ==============================================================================
# GPU-enabled Jupyter for NORTH -- mirrors the jupyter_builder/jupyter pair above
# on a CUDA base. See the GPU-NORTH deployment runbook, Phase 2 (not in this public repo).
#
# A GPU in the container is useless without CUDA userspace libs, so the BASE IMAGE
# -- not a flag -- is what makes this work. The `use_gpu: true` flag in nomad.yaml
# (Phase 6) only attaches the device; it installs nothing.
#
# Layering the NOMAD plugin env onto a torch base is safe ONLY because uv.lock
# contains no torch and no nvidia-* packages, and `uv sync --inexact` preserves
# pre-installed packages -- so the base image's CUDA torch survives untouched.
# IF A PLUGIN EVER ADDS A TORCH DEPENDENCY, RE-VERIFY: uv would then resolve torch
# from PyPI and could silently replace the CUDA build with a different one.
#
# Build target: jupyter_gpu -> publish as
# ghcr.io/crc270-hommage/nomad-oasis/jupyter-gpu:main
# Build it LOCALLY ON TITAN first (multi-GB); promote to CI only once it works.
# ==============================================================================
FROM ${JUPYTER_GPU_IMAGE} AS jupyter_gpu_builder

ENV UV_PROJECT_ENVIRONMENT=/opt/conda \
    UV_FROZEN=1

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      gcc \
      build-essential \
      curl \
      zip \
      unzip \
      git \
      # clean cache and logs
      && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}
WORKDIR "${HOME}"

COPY --from=uv_image /uv /bin/uv

# ⚠️ Purge the base image's alembic BEFORE syncing. `--inexact` (below) protects the base's
# CUDA torch by never removing pre-installed packages -- which also means uv overwrites a
# base-installed package's files WITHOUT deleting the files that version had and uv's does
# not. That orphaning is longstanding and normally harmless; it is invisible whenever the two
# versions share a file layout. The older base orphaned alembic 1.15.2 under uv's 1.16.5 for
# weeks with no ill effect.
#
# It stopped being harmless with the 2026-08-03 base (see JUPYTER_GPU_IMAGE above), which
# ships alembic 1.18.5 against uv.lock's 1.16.5. Alembic turned `autogenerate/compare` from a
# module into a PACKAGE between those versions, so the orphan was a `compare/` directory
# sitting next to uv's `compare.py` -- and a package shadows a same-named module. The base's
# 1.18.5 code won the import and called into uv's 1.16.5 `util`:
#     ImportError: cannot import name 'PriorityDispatchResult' from 'alembic.util'
# `jupyterhub-singleuser` died on import, so every GPU NORTH session started, exited 1 after
# ~2s, and left the hub waiting out its full 300s timeout -- surfacing to users as "spawn
# timed out", three hops from the cause. `conda list` still reported a clean "alembic 1.16.5";
# the only on-disk trace was two alembic-*.dist-info directories. Broke 2026-08-06 16:37 (the
# commit that pointed NORTH at this image), found 2026-08-11, masked for three days in between
# by an unrelated GPU driver outage that failed spawns one hop earlier.
#
# Do NOT "fix" this by dropping --inexact: that would replace the base's CUDA torch. The next
# base bump may collide on some other package, so this line is only the specific remedy --
# the singleuser smoke test in the final stage below is the general guard.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    # Use inexact to avoid removing pre-installed packages in the environment
    # -- this is what protects the base image's CUDA torch, see the note above
    # Use no-install-project to skip installing the current project (`nomad-distribution`)
    uv pip uninstall --python /opt/conda/bin/python alembic \
 && uv sync --extra plugins --extra jupyter --no-install-project --inexact


FROM ${JUPYTER_GPU_IMAGE} AS jupyter_gpu
# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

RUN apt-get update \
 && apt-get install --yes --quiet --no-install-recommends \
      libgomp1 \
      libmagic1 \
      file \
      curl \
      zip \
      unzip \
      git \
      # `nbconvert` dependencies
      # https://nbconvert.readthedocs.io/en/latest/install.html#installing-tex
      texlive-xetex \
      texlive-fonts-recommended \
      texlive-plain-generic \
      # clean cache and logs
      && rm -rf /var/lib/apt/lists/* /var/log/* /var/tmp/* ~/.npm

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}
WORKDIR "${HOME}"

COPY --from=uv_image /uv /bin/uv

# ⚠️ Purge the base's alembic before the COPY merges the builder's tree in. See the `jupyter`
# stage for the full explanation -- the short version is that this stage shares the builder's
# base image, so it has a second copy of the base's alembic, and COPY merges rather than
# replaces. Cleaning the builder alone provably does not work.
RUN uv pip uninstall --python /opt/conda/bin/python alembic
COPY --from=jupyter_gpu_builder /opt/conda /opt/conda

# ⚠️ SMOKE TEST — do not remove. See the identical guard in the `jupyter` stage for why a
# broken singleuser is invisible to a manual `docker run`. This is the check that would have
# caught the alembic collision documented in jupyter_gpu_builder at build time instead of
# three days later, and it is the general guard for whatever the NEXT base bump collides on.
RUN python -c "import jupyterhub.singleuser" \
 && jupyterhub-singleuser --version

# Get rid ot the following message when you open a terminal in jupyterlab:
# groups: cannot find name for group ID 11320
RUN touch ${HOME}/.hushlogin
