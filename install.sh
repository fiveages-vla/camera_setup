#!/bin/bash
# Install system dependencies for the Orbbec ROS2 camera setup (ROS 2 Jazzy).
# Usage: ./install.sh
set -euo pipefail

ROS_DISTRO_NAME=jazzy
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SDK_DIR="${REPO_DIR}/OrbbecSDK_ROS2"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "==> Installing apt packages"
$SUDO apt update
$SUDO apt install -y \
  libusb-1.0-0-dev libgflags-dev python3-rosdep python3-colcon-common-extensions \
  ros-${ROS_DISTRO_NAME}-rmw-zenoh-cpp \
  ros-${ROS_DISTRO_NAME}-compressed-image-transport \
  ros-${ROS_DISTRO_NAME}-rqt-image-view

echo "==> Installing Orbbec udev rules"
$SUDO bash "${SDK_DIR}/orbbec_camera/scripts/install_udev_rules.sh"

echo "==> Resolving ROS dependencies with rosdep"
# setup.bash references unset variables, so relax -u while sourcing
set +u
source "/opt/ros/${ROS_DISTRO_NAME}/setup.bash"
set -u
$SUDO rosdep init 2>/dev/null || true
rosdep update
rosdep install --from-paths "${SDK_DIR}" --ignore-src -r -y

echo "==> Done"
