# syntax=docker/dockerfile:1.6
###############################################################################
# pySLAM container image
#
#   CPU : x86-64, compiled with -march=skylake (AVX2/FMA/BMI2)
#         -> runs on Intel Skylake and newer, and AMD Zen 2+
#   GPU : NVIDIA Turing (sm_75) / Ampere (sm_80, sm_86) on CUDA 12.8
#         (torch 2.9.1+cu128, OpenCV CUDA modules, faiss-gpu-cu12,
#          detectron2 built for sm_75/80/86)
#
# The image is built by GitHub Actions and pushed to:
#   ghcr.io/<owner>/pyslam-docker
#
# Upstream: https://github.com/luigifreda/pyslam (MIT license)
###############################################################################
FROM nvidia/cuda:12.8.1-devel-ubuntu22.04

ARG PYSLAM_REF=a5ff2562eb929ed9a08420f528a120a3cca65585
ARG DEBIAN_FRONTEND=noninteractive

# ---- base tooling + runtime libs (X11/GTK for the pangolin viewer) ---------
RUN apt-get update && apt-get install -y --no-install-recommends \
      sudo lsb-release git git-lfs ca-certificates curl wget tzdata \
      build-essential pkg-config \
      libgl1 libglu1-mesa libsm6 libxext6 libxrender1 \
      libxkbcommon-x11-0 libglib2.0-0 \
    && ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'Defaults env_keep += "DEBIAN_FRONTEND PYSLAM_CUDA_ARCH_BIN TORCH_CUDA_ARCH_LIST"' \
        > /etc/sudoers.d/env_keep \
    && chmod 440 /etc/sudoers.d/env_keep

# ---- optimization targets ---------------------------------------------------
# CPU: everything compiled from source (python 3.11 via pyenv, OpenCV, g2o,
#      GTSAM, Ceres, DBoW2, orbslam2_features, pyslam C++ core, detectron2)
#      picks these up.
# GPU: TORCH_CUDA_ARCH_LIST drives torch extensions (detectron2 CUDA ops);
#      PYSLAM_CUDA_ARCH_BIN clamps the OpenCV CUDA build below.
ENV TARGET_MARCH="skylake" \
    CFLAGS="-march=skylake -mtune=skylake -O3 -pipe" \
    CXXFLAGS="-march=skylake -mtune=skylake -O3 -pipe" \
    PYSLAM_CUDA_ARCH_BIN="7.5 8.0 8.6" \
    TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6" \
    FORCE_CUDA=1 \
    MAKE_OPTS="-j4" \
    PIP_NO_CACHE_DIR=1

# ---- fetch pySLAM at a pinned ref -------------------------------------------
# NOTE: git fetch by SHA needs the FULL 40-char commit id on GitHub; short
# prefixes are rejected ("couldn't find remote ref").
WORKDIR /opt
RUN git clone --recursive --depth 1 https://github.com/luigifreda/pyslam.git pyslam \
 && cd pyslam \
 && ( git fetch --depth 1 origin "${PYSLAM_REF}" \
      && git checkout --detach FETCH_HEAD \
      || git checkout --detach "${PYSLAM_REF}" ) \
 && git submodule sync --recursive \
 && git submodule update --init --recursive --depth 1 \
 && echo "${PYSLAM_REF}" > /opt/pyslam/.image_ref

# ---- clamp OpenCV CUDA arch list to Turing + Ampere -------------------------
# The stock script auto-detects arches via `nvcc --list-gpu-arch`, which on a
# CUDA 12.8 devel image returns EVERY supported arch (sm_50 .. sm_120) and
# would make the OpenCV CUDA build take many hours. Override with the exact
# target list; see scripts/install_opencv_local.sh in pyslam.
RUN sed -i 's|CUDA_ARCH_BIN=$(get_cuda_arch_bin)|CUDA_ARCH_BIN="${PYSLAM_CUDA_ARCH_BIN:-7.5 8.0 8.6}"|' \
        /opt/pyslam/scripts/install_opencv_local.sh \
 && grep -qF 'CUDA_ARCH_BIN="${PYSLAM_CUDA_ARCH_BIN' /opt/pyslam/scripts/install_opencv_local.sh

# ---- run the official unified installer -------------------------------------
# install_all.sh is docker-aware (skips sudo keep-alive on /.dockerenv) and
# with no conda/pixi present it takes the venv route:
#   system packages -> pyenv + python 3.11.9 venv (~/.python/venvs/pyslam)
#   -> pip packages (torch 2.9.1+cu128 via download.pytorch.org)
#   -> thirdparty builds (OpenCV+contrib w/ CUDA, g2o, GTSAM, DBoW2, ...)
#   -> C++ core (pybind11) -> semantic stack (detectron2 v0.6 + patch, ...)
WORKDIR /opt/pyslam
RUN ./install_all.sh < /dev/null

# ---- fail the build loudly if the environment is broken ---------------------
# (install_all.sh does not run with `set -e`, so verify the key imports)
RUN . ./pyenv-activate.sh \
 && python -c "import torch;    print('torch', torch.__version__, 'cuda', torch.version.cuda)" \
 && python -c "import cv2;      print('cv2', cv2.__version__)" \
 && python -c "import detectron2, detectron2._C; print('detectron2 ok')" \
 && python -c "import pyslam;   print('pyslam import ok')" \
 && (python -c "import faiss; print('faiss ok')" || echo "WARN: faiss import failed")

# ---- trim build intermediates ------------------------------------------------
# Keep: thirdparty/opencv/install (C++ core links against it), cpp/build and
# detectron2 in-place .so. Remove: opencv build tree + git metadata.
RUN rm -rf \
      thirdparty/opencv/build \
      thirdparty/opencv/opencv/.git \
      thirdparty/opencv/opencv_contrib/.git \
      thirdparty/detectron2/build \
      /root/.pyenv/cache /root/.cache/pip \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# ---- default runtime environment ---------------------------------------------
ENV VIRTUAL_ENV=/root/.python/venvs/pyslam \
    PATH="/root/.pyenv/bin:${VIRTUAL_ENV}/bin:${PATH}" \
    TF_CPP_MIN_LOG_LEVEL=3

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
WORKDIR /opt/pyslam
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
