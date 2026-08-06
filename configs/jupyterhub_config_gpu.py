"""GPU overlay for the NORTH hub on titan (.102).

TEMPORARY. Delete this file the moment upstream PR #6 (FAIRmat-NFDI/nomad-north,
"Providing backward compatibility") is merged and released -- see "Removing this file" below.

WHY IT EXISTS
-------------
`ghcr.io/fairmat-nfdi/nomad-north:main` does not implement `use_gpu`. Its Profile model carries
only display_name/default/description/slug/image/default_url, and `pre_spawn_hook` sets only
`image`, `default_url` and `mounts`. So `use_gpu: true` in nomad.yaml is read by the NOMAD app,
served in /north/tools/, and then silently dropped -- with no log line, because the
"GPU requested but no nvidia driver found" warning lives in nomad-lab's app-image hub, which this
deployment stopped using on 2026-08-05. Upstream issue #5 tracks the same gap for `privileged`
and `seccomp_unconfined`.

WHAT IT DOES
------------
Layers a spawner-level device request on top of the shipped config, without modifying the image.
The hub's own Dockerfile leaves CMD commented out, so it is started explicitly with
`-f <this file>` (see docker-compose.north.yml).

Every session on titan gets BOTH GPUs. That is not a compromise: after the NORTH split all
sessions run here, and the upstream mechanism is `count=-1` -- all GPUs to every GPU session --
so per-tool granularity would not have partitioned anything either. The 3090s are GeForce, so
MIG is unavailable and there is no partitioning knob to reach for.

REMOVING THIS FILE (when PR #6 lands)
-------------------------------------
1. Drop the `command:` override and this file's volume mount from docker-compose.north.yml.
2. Delete this file.
3. Nothing else. `use_gpu: true` is already in configs/nomad.yaml and becomes load-bearing on
   its own -- which is exactly why it is set there today even though it is currently inert.
Verify afterwards with Phase 7 step 2a: HostConfig.DeviceRequests on a running session must be
non-empty. Note the failure modes differ -- the merged image checks for an nvidia driver first
and quietly disables the GPU if absent, whereas this overlay requests it unconditionally and a
missing driver surfaces as a container start error instead.
"""

from docker.types import DeviceRequest

# Load the image's shipped config first; everything below layers on top of it. Passed as
# (filename, path) rather than one absolute string -- that is the documented form and avoids
# depending on how filefind treats an absolute name.
load_subconfig('jupyterhub_config.py', path='/srv/jupyterhub')  # type: ignore # noqa: F821

# get_config() must be called explicitly: traitlets injects `get_config` and `load_subconfig`
# into a config file's namespace, but NOT `c` itself. Called after load_subconfig so it is
# unambiguously the merged config object.
c = get_config()  # type: ignore # noqa: F821

# Config set on DockerSpawner applies to NORTHSpawner too (traitlets resolves config through the
# MRO) -- the shipped config relies on the same thing for prefix/network_name/timeouts, and it
# never sets extra_host_config, so this cannot clobber anything.
#
# DeviceRequest rather than a raw dict is deliberate: docker-py accepts both, but the object
# spares us guessing at API key casing, and it mirrors nomad-lab's own call exactly.
# count=-1 is the API equivalent of `docker run --gpus all`.
c.DockerSpawner.extra_host_config = {
    'device_requests': [DeviceRequest(count=-1, capabilities=[['gpu']])]
}
