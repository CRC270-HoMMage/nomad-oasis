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

Sessions of a GPU image (GPU_IMAGES below) get BOTH GPUs; every other tool gets none. Handing
out both is not a compromise: the upstream mechanism is `count=-1` -- all GPUs to every GPU
session -- so finer granularity would not have partitioned anything either. The 3090s are
GeForce, so MIG is unavailable and there is no partitioning knob to reach for. Restricting it
to GPU images is not optional, though: see gpu_host_config() for what a device request does to
a CPU-only tool when the driver is down.

REMOVING THIS FILE (when PR #6 lands)
-------------------------------------
1. Drop the `command:` override and this file's volume mount from docker-compose.north.yml.
2. Delete this file.
3. Nothing else. `use_gpu: true` is already in configs/nomad.yaml and becomes load-bearing on
   its own -- which is exactly why it is set there today even though it is currently inert.
Verify afterwards with Phase 7 step 2a: HostConfig.DeviceRequests on a running session must be
non-empty, and empty on a CPU-only tool such as smco-toolkit. Note the failure modes differ --
the merged image checks for an nvidia driver first and quietly disables the GPU if absent,
whereas this overlay requests it for GPU images regardless, so a missing driver surfaces as a
container start error for those instead.
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

# Images that get the GPUs. Only these: a CPU-only tool (e.g. smco-toolkit) given a device
# request fails to START whenever the host's nvidia driver is unavailable -- "nvml error: driver
# not loaded" from the prestart hook -- although it never touches a GPU. That took down every
# NORTH tool at once on 2026-09-29.
#
# ⚠️ PAIRED with the jupyter tool's `image:` in configs/nomad.yaml (and the jupyterlab_image
# pre-pull in docker-compose.north.yml). If that ref changes and this set does not, Jupyter
# silently loses its GPUs -- nothing errors, torch just reports no CUDA device.
GPU_IMAGES = {'ghcr.io/crc270-hommage/nomad-oasis/jupyter-gpu:main'}


def gpu_host_config(spawner):
    # dockerspawner >= 13 calls a callable extra_host_config with the spawner at container
    # creation, after NORTHSpawner's pre_spawn_hook has set spawner.image from the tool profile.
    #
    # DeviceRequest rather than a raw dict is deliberate: docker-py accepts both, but the object
    # spares us guessing at API key casing, and it mirrors nomad-lab's own call exactly.
    # count=-1 is the API equivalent of `docker run --gpus all`.
    if spawner.image in GPU_IMAGES:
        return {'device_requests': [DeviceRequest(count=-1, capabilities=[['gpu']])]}
    return {}


# Config set on DockerSpawner applies to NORTHSpawner too (traitlets resolves config through the
# MRO) -- the shipped config relies on the same thing for prefix/network_name/timeouts, and it
# never sets extra_host_config, so this cannot clobber anything.
c.DockerSpawner.extra_host_config = gpu_host_config
