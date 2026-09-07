# pyslam-docker

用 GitHub Actions 自动构建的 [pySLAM](https://github.com/luigifreda/pyslam) 容器镜像，发布在 GHCR（公开，无需登录即可拉取）：

```
ghcr.io/alice7371/pyslam-docker:latest          # 跟踪 main 分支
ghcr.io/alice7371/pyslam-docker:cu128-skylake   # 同上，带架构标注
ghcr.io/alice7371/pyslam-docker:main-<sha>      # 每次构建的 commit 快照
```

## 目标平台

| 维度 | 配置 |
|---|---|
| CPU | x86-64，全部源码产物按 `-march=skylake -mtune=skylake -O3` 编译（AVX2/FMA/BMI2），可在 Skylake 及更新的 Intel、AMD Zen2+ 上运行 |
| GPU | NVIDIA Turing（sm_75，如 RTX 20xx / T4）与 Ampere（sm_80/sm_86，如 A100 / RTX 30xx / A10） |
| CUDA | 12.8（基础镜像 `nvidia/cuda:12.8.1-devel-ubuntu22.04`；torch 2.9.1+cu128、OpenCV CUDA 模块、faiss-gpu-cu12、detectron2 CUDA 算子均按 `7.5/8.0/8.6` 三档架构编译） |

## 使用

```bash
# 需要宿主机有 NVIDIA 驱动 + nvidia-container-toolkit；查看器走 X11 转发
xhost +local:docker

docker run --gpus all -it --rm \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v $HOME/pyslam-datasets:/data \
  ghcr.io/alice7371/pyslam-docker:latest

# 容器内（已自动激活 pyslam venv，工作目录 /opt/pyslam）
./download_datasets.py            # 数据集下到 /data（把 data 软链过去）
python scripts/opencv_check.py
python main_slam.py -k orbslam2 --dataset datasets/ETH/odometry/gray/sequences/00
```

镜像内 pyslam 位于 `/opt/pyslam`，Python 环境为 venv `~/.python/venvs/pyslam`（Python 3.11.9，pyenv 构建），入口 `entrypoint.sh` 会自动 `source pyenv-activate.sh`。

## 构建

- 推送到 `main`（改动 `Dockerfile` / `docker/` / workflow 本身）自动触发；每周一 18:00 UTC 定时重建刷新基础镜像；也可在 Actions 页面手动 `workflow_dispatch`，支持传入 `pyslam_ref`（commit / tag / 分支）构建任意 pyslam 版本。
- 默认 pin 到 pyslam master `a5ff2562e`（完整 SHA `a5ff2562eb929ed9a08420f528a120a3cca65585`，2026-08-23）保证可复现。
- 构建走官方 `install_all.sh`（venv 路线），完成后做 `torch/cv2/detectron2/pyslam` 导入冒烟测试，防静默半装。
- 镜像较大（约 15–20 GB）：devel 基础镜像 + cu128 torch + OpenCV install 树 + 预下载的特征模型；层缓存存放在 GHCR 的 `buildcache` tag，定时重建通常只需几分钟。

## 与上游安装脚本的差异（仅一处）

`scripts/install_opencv_local.sh` 里 OpenCV 的 CUDA 架构由 `nvcc --list-gpu-arch` 自动检测，在 CUDA 12.8 devel 基础镜像下会得到 sm_50–sm_120 全量列表，编译耗时不可接受。构建时用 `sed` 将其钳制为环境变量 `PYSLAM_CUDA_ARCH_BIN="7.5 8.0 8.6"`（Turing + Ampere）。其余步骤与上游完全一致。

## 许可

本仓库的构建脚本以 MIT 发布；pySLAM 本体及其第三方依赖遵循各自的上游许可。
