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
#
# The official install_all.sh is split into phases below (same sub-scripts,
# same order as scripts/install_all_venv.sh): a single monolithic RUN died
# with the whole runner (16 GB RAM, -j4 Eigen/nvcc TUs) and one lost layer
# cost a full 3.5 h rebuild.
###############################################################################
FROM nvidia/cuda:12.8.1-devel-ubuntu22.04 AS base

SHELL ["/bin/bash", "-c"]

ARG PYSLAM_REF=a5ff2562eb929ed9a08420f528a120a3cca65585
ARG PYSLAM_PYTHON_VERSION=3.11.9
ARG DEBIAN_FRONTEND=noninteractive

# ---- base tooling + runtime libs (X11/GTK for the pangolin viewer) ---------
RUN apt-get update && apt-get install -y --no-install-recommends \
      sudo lsb-release git git-lfs ca-certificates curl wget tzdata \
      build-essential pkg-config \
      libgl1 libglu1-mesa libsm6 libxext6 libxrender1 \
      libxkbcommon-x11-0 libglib2.0-0 \
    && ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'Defaults env_keep += "DEBIAN_FRONTEND PYSLAM_CUDA_ARCH_BIN TORCH_CUDA_ARCH_LIST MAKEFLAGS"' \
        > /etc/sudoers.d/env_keep \
    && chmod 440 /etc/sudoers.d/env_keep

# ---- optimization targets ---------------------------------------------------
# CPU: everything compiled from source (python 3.11 via pyenv, OpenCV, g2o,
#      GTSAM, Ceres, DBoW2, orbslam2_features, pyslam C++ core, detectron2)
#      picks these up.
# GPU: TORCH_CUDA_ARCH_LIST drives torch extensions (detectron2 CUDA ops);
#      PYSLAM_CUDA_ARCH_BIN clamps the OpenCV CUDA build below.
# MAKEFLAGS=-j2: the GH runner has 16 GB RAM; -j4 parallel Eigen/nvcc
#      translation units OOM-killed the whole runner mid-build.
ENV TARGET_MARCH="skylake" \
    CFLAGS="-march=skylake -mtune=skylake -O3 -pipe" \
    CXXFLAGS="-march=skylake -mtune=skylake -O3 -pipe" \
    PYSLAM_CUDA_ARCH_BIN="7.5 8.0 8.6" \
    TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6" \
    FORCE_CUDA=1 \
    MAKEFLAGS="-j2" \
    PIP_NO_CACHE_DIR=1

# ---- pre-install pyenv + the exact python pyslam expects --------------------
# pyslam's scripts/install_pyenv.sh is broken under docker build: it appends
# pyenv init to ~/.bashrc (never sourced in non-interactive shells) and only
# prepends $PYENV_ROOT/shims (not bin) to PATH, so `pyenv` stays unfindable,
# `pyenv install 3.11.9` silently fails and the venv falls back to the system
# python 3.10 (which violates pyslam's requires-python >= 3.11.9).
# Pre-baking pyenv here makes pyslam's pyenv install a no-op and its
# `python3 -m venv` pick 3.11.9 through the shims.
ENV PYENV_ROOT=/root/.pyenv
ENV PATH="${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}"
RUN apt-get update && apt-get install -y --no-install-recommends \
      make libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
      libncursesw5-dev xz-utils tk-dev libffi-dev liblzma-dev unzip \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 https://github.com/pyenv/pyenv.git "${PYENV_ROOT}" \
    && pyenv install "${PYSLAM_PYTHON_VERSION}" \
    && pyenv global "${PYSLAM_PYTHON_VERSION}" \
    && python3 --version && pyenv version

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
WORKDIR /opt/pyslam

# ---- patch pyslam build scripts for this environment ------------------------
# 1) clamp OpenCV CUDA arch list to Turing + Ampere: the stock script uses
#    `nvcc --list-gpu-arch`, which on a CUDA 12.8 devel image returns EVERY
#    arch (sm_50..sm_120) and would make the build take many hours.
# 2) cap make parallelism to -j2 everywhere (runner RAM, see MAKEFLAGS note);
#    explicit -j flags in the sub-scripts would override the env var.
# NOTE: no bare trailing "|| true" here — it would swallow upstream && failures.
RUN sed -i 's|CUDA_ARCH_BIN=$(get_cuda_arch_bin)|CUDA_ARCH_BIN="${PYSLAM_CUDA_ARCH_BIN:-7.5 8.0 8.6}"|' \
        scripts/install_opencv_local.sh \
 && grep -qF 'CUDA_ARCH_BIN="${PYSLAM_CUDA_ARCH_BIN' scripts/install_opencv_local.sh \
 && find . -name '*.sh' -not -path '*/.git/*' \
      -exec sed -i -E 's/-j[[:space:]]*\$\(\s*nproc\s*\)/-j2/g; s/-j\s*\$\{NPROC\}/-j2/g; s/([[:space:]])-j[[:space:]]*4\b/\1-j2/g' {} + \
 && { grep -rEn -- '-j\$\(nproc\)' --include='*.sh' . | head -5 || true; }

# ---- phase 1: system packages + pyslam venv (python 3.11.9 via pyenv) -------
RUN ./scripts/install_system_packages.sh < /dev/null \
 && ./scripts/pyenv-venv-create.sh < /dev/null \
 && . ./pyenv-activate.sh && python3 --version

# ---- phase 2: git modules (feature models) + pip stack ----------------------
# (opencv from source w/ CUDA + nonfree, torch 2.9.1+cu128, faiss-gpu-cu12)
# Opencv source + build trees are deleted in the SAME layer: only the
# install/ tree and the installed python wheel are used later. Keeping them
# cost ~10 GB of runner disk (a disk-full killed a build once).
RUN . ./pyenv-activate.sh \
 && export WITH_PYTHON_INTERP_CHECK=ON \
 && ./scripts/install_git_modules.sh < /dev/null \
 && . ./scripts/install_pip3_packages.sh \
 && python -c "import torch, cv2; print('torch', torch.__version__, torch.version.cuda, '| cv2', cv2.__version__)" \
 && rm -rf thirdparty/opencv/opencv-[0-9]* thirdparty/opencv/opencv_contrib* \
          thirdparty/opencv/build /root/.pyenv/cache \
 && df -h / | tail -1

# ---- builder checkpoint stage: phases 1-2 above are pushed as :builder -----
# and exported to the registry cache, so later-phase failures do not restart
# the expensive python/opencv/pip stack from scratch.
FROM base AS full

# ---- phase 3: thirdparty C++ (open3d, g2opy, GTSAM, DBoW2, ...) -------------
# Disk is the constraint on GH runners (a full disk killed two builds here).
# install_thirdparty.sh compiles open3d from source: the resulting wheel is
# pip-installed into the venv, so the whole thirdparty/open3d tree (~15 GB
# source+build) is dead weight afterwards. Also drop any */build tree that
# has an install/ sibling (cmake-install pattern; gtsam_local); in-tree
# pybind builds (g2opy, pydbow*, ...) have no install sibling and are kept.
RUN . ./pyenv-activate.sh \
 && export WITH_PYTHON_INTERP_CHECK=ON \
 && . ./scripts/install_thirdparty.sh \
 && echo '--- thirdparty sizes before cleanup ---' \
 && du -sh thirdparty/* 2>/dev/null | sort -h | tail -15 \
 && rm -rf thirdparty/open3d /root/.cache /tmp/pip-* \
 && for d in thirdparty/*/build; do \
        [ -d "$d" ] && [ -d "$(dirname "$d")/install" ] && rm -rf "$d" || true; \
    done \
 && echo '--- thirdparty sizes after cleanup ---' \
 && du -sh thirdparty/* 2>/dev/null | sort -h | tail -15 \
 && df -h / | tail -1

# ---- phase 3b: pyslam C++ core against the built thirdparty -----------------
RUN . ./pyenv-activate.sh \
 && export WITH_PYTHON_INTERP_CHECK=ON \
 && . ./scripts/install_cpp.sh \
 && df -h / | tail -1

# ---- phase 4: semantic stack + outlier pins (mirrors install_all_venv.sh) ---
# Fail fast instead of hanging mid-download when disk runs out.
RUN AVAIL=$(df --output=avail -BG / | tail -1 | tr -dc '0-9'); \
    echo "free disk: ${AVAIL}G"; [ "$AVAIL" -gt 12 ] || { echo 'FATAL: low disk before semantics'; false; }
RUN . ./pyenv-activate.sh \
 && export WITH_PYTHON_INTERP_CHECK=ON \
 && ./scripts/install_pip3_semantics.sh < /dev/null \
 && pip install "pyarrow<19" \
 && ./scripts/install_protobuf.sh < /dev/null \
 && pip install "wandb>=0.25.1,<0.26" --force-reinstall \
 && ./scripts/detectron_check.sh < /dev/null \
 && pip install "numpy<2" --force-reinstall \
 && df -h / | tail -1

# ---- phase 5: pyslam C++ core (pybind11 modules) -----------------------------
RUN . ./pyenv-activate.sh \
 && ./build_cpp_core.sh < /dev/null \
 && df -h / | tail -1

# ---- fail the build loudly if the environment is broken ---------------------
RUN . ./pyenv-activate.sh \
 && python -c "import sys; assert sys.version_info[:2] == (3, 11), sys.version; print('python', sys.version.split()[0])" \
 && python -c "import torch; v=torch.version.cuda; assert v and v.startswith('12'), v; print('torch', torch.__version__, 'cuda', v, 'archs', torch.cuda.get_arch_list())" \
 && python -c "import cv2;      print('cv2', cv2.__version__)" \
 && python -c "import detectron2, detectron2._C; print('detectron2 ok')" \
 && python -c "import pyslam;   print('pyslam import ok')" \
 && (python -c "import faiss; print('faiss ok')" || echo "WARN: faiss import failed")

# ---- trim build intermediates ------------------------------------------------
# Keep: thirdparty/opencv/install (C++ core links against it), cpp/build and
# detectron2 in-place .so. Remove: git metadata.
RUN rm -rf \
      thirdparty/opencv/opencv \
      thirdparty/detectron2/build \
      /root/.pyenv/cache /root/.cache/pip \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# ---- default runtime environment ---------------------------------------------
ENV VIRTUAL_ENV=/root/.python/venvs/pyslam \
    PATH="${VIRTUAL_ENV}/bin:${PATH}" \
    TF_CPP_MIN_LOG_LEVEL=3

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
WORKDIR /opt/pyslam
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
