# Ubuntu 24.04 — OS Preparation Guide

This guide walks through preparing a Ubuntu 24.04 LTS (Noble Numbat) instance for GPU-accelerated containerized workloads:

0. [Starting point — Nutanix Cloud Image vs. Bare-Metal](#0-starting-point--nutanix-cloud-image-vs-bare-metal)
1. [Lock to a specific kernel version](#1-lock-to-a-specific-kernel-version)
2. [Update & upgrade all other packages](#2-update--upgrade-all-other-packages)
3. [Install a specific NVIDIA driver](#3-install-a-specific-nvidia-driver)
4. [Install the latest Docker Engine](#4-install-the-latest-docker-engine)
5. [Install NVIDIA Container Toolkit (CTK)](#5-install-nvidia-container-toolkit-ctk)

---

## 0. Starting Point — Nutanix Cloud Image or Bare-Metal

Before running any of the steps below, you need a running Ubuntu 24.04 instance. Two supported paths:

### Option A — Nutanix Cloud Image (AHV VM)

Ubuntu publishes minimal, pre-built cloud images designed for fast VM provisioning. On Nutanix AHV, upload the image once to the Image Service and reuse it across nodes.

**Image URL:**

```
https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

1. In **Prism Central** → Images → Add Image → select **URL** and paste the link above.
2. Create a new VM with (adjust CPU and memory based on your workload), attach the uploaded image as the boot disk, resize the disk as needed (container and models can take a lot of space), and add a **cloud-init** disk with the following user-data:

```yaml
#cloud-config
users:
  - name: nutanix
    gecos: Nutanix Nutanix
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    groups: sudo
    ssh_authorized_keys:
      - ssh-ed25519 XXXXX
```

3. Power on the VM — `cloud-init` runs on first boot, sets the hostname, user, and SSH key, then the system is reachable via SSH.

---

### Option B — Bare-Metal Server ISO

Use the **Ubuntu 24.04 LTS Server ISO** for physical machines.

1. Download from [releases.ubuntu.com/noble](https://releases.ubuntu.com/noble/) — choose `ubuntu-24.04.x-live-server-amd64.iso`.
2. Boot the ISO and follow the **Subiquity** installer:
   - Select **minimized installation**.
   - Configure storage (LVM or ZFS) as needed.
   - Enable **OpenSSH server** during install.
   - **Do not** install third-party drivers at this stage — the NVIDIA driver is handled in step 3.
3. Complete the install and boot into the new system.


---

### Prerequisites

After you have your Ubuntu 24.04 instance up and running (via either path), log in and run the following to ensure you have the necessary tools for the steps ahead.


```bash
sudo apt-mark hold linux-image-generic linux-headers-generic
sudo apt update
sudo apt install -y curl gnupg lsb-release ca-certificates software-properties-common apt-transport-https
```

---

## 1. Lock to a Specific Kernel Version

### 1.1 — List installed kernels

```bash
dpkg --list | grep linux-image
uname -r        # currently running kernel
```

### 1.2 — Install the target kernel (if not already present)

To align with NKP 2.17.1 we want to use the kernel version **6.8.0-101**.


```bash
KERNEL_VERSION="6.8.0-101"

sudo apt install -y \
  linux-image-${KERNEL_VERSION}-generic \
  linux-headers-${KERNEL_VERSION}-generic 
```

### 1.3 — Hold the kernel packages

`apt-mark hold` prevents `apt upgrade` from replacing or removing these packages.

```bash
KERNEL_VERSION="6.8.0-101"

sudo apt-mark hold \
  linux-image-${KERNEL_VERSION}-generic \
  linux-headers-${KERNEL_VERSION}-generic
```

Verify held packages:

```bash
apt-mark showhold
```

### 1.4 — Reboot and confirm

```bash
sudo reboot
# After reboot:
uname -r        # must show the pinned version
```

---

## 2. Update & Upgrade All Other Packages

With the kernel held, a full upgrade will update userland packages only.

```bash
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
sudo apt clean
```

---

## 3. Install a Specific NVIDIA Driver

The runfile method installs a self-contained, version-pinned driver independently of the distro package manager.

**Runfile used in this guide to align with NKP 2.17.1:** `NVIDIA-Linux-x86_64-580.95.05.run` (driver branch 580)

### 3.1 — Install build dependencies

The runfile compiles a kernel module on the fly and requires the matching kernel headers.

```bash
sudo apt install -y \
  build-essential \
  pkg-config \
  libglvnd-dev \
  linux-headers-$(uname -r)
```

### 3.2 — Download the runfile

```bash
RUNFILE="NVIDIA-Linux-x86_64-580.95.05.run"

curl -Lo /tmp/${RUNFILE} \
  https://us.download.nvidia.com/tesla/580.95.05/${RUNFILE}

chmod +x /tmp/${RUNFILE}
```

### 3.3 — Run the installer


```bash
sudo /tmp/${RUNFILE} \
  --dkms \
  --no-questions
```

### 3.4 — Reboot and verify

```bash
sudo reboot
# After reboot:
nvidia-smi
```

Expected output includes driver version `580.95.05`, CUDA version, and a list of GPUs.

---

## 4. Install the Latest Docker Engine

Install directly from Docker's official repository — **not** the Ubuntu-packaged `docker.io`.

### 4.1 — Remove any old / distro-packaged Docker

```bash
sudo apt remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
sudo apt update
```

### 4.2 — Add Docker's official GPG key and repository

```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
```

### 4.3 — Install Docker Engine

```bash
sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
```

### 4.4 — Post-install configuration

```bash
# Allow the current user to run Docker without sudo
sudo usermod -aG docker $USER

# Enable Docker on boot and start it now
sudo systemctl enable --now docker
```

> Log out and back in (or run `newgrp docker`) for the group change to take effect.

### 4.5 — Verify

```bash
docker version
```

---

## 5. Install NVIDIA Container Toolkit (CTK)

The NVIDIA Container Toolkit lets Docker (and other runtimes) expose GPU devices inside containers.

### 5.1 — Add the NVIDIA CTK repository

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

### 5.2 — Install the toolkit

```bash
sudo apt update
sudo apt install -y nvidia-container-toolkit
```

### 5.3 — Configure Docker to use the NVIDIA runtime

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

This writes an `nvidia` runtime entry into `/etc/docker/daemon.json`:

```json
{
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "args": []
    }
  }
}
```

### 5.4 — Verify

```bash
# Run nvidia-smi inside a container — should show the same GPUs as on the host
docker run --rm --gpus all \
  nvidia/cuda:12.6.0-base-ubuntu24.04 \
  nvidia-smi
```

## 6. Python Environment

