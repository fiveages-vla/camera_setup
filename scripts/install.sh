#!/bin/bash
# Install dependencies and build the Orbbec ROS2 driver (ROS 2 Jazzy).
# Usage: ./scripts/install.sh
set -euo pipefail

ROS_DISTRO_NAME=jazzy
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SDK_DIR="${REPO_DIR}/OrbbecSDK_ROS2"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "==> Removing stale colcon build artifacts"
# Build outputs copied from another machine/arch are invalid; rebuild on this one.
for stale in build install log; do
  rm -rf "${SDK_DIR:?}/${stale}"
done

echo "==> Installing apt packages"
$SUDO apt update
$SUDO apt install -y \
  libusb-1.0-0-dev libgflags-dev python3-rosdep python3-colcon-common-extensions \
  python3-opencv python3-numpy \
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

echo "==> Building OrbbecSDK_ROS2 with colcon"
# Clean environment so a stray overlay workspace cannot leak into the build.
env -i HOME="$HOME" LANG="${LANG:-C.UTF-8}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  bash --noprofile --norc -c '
set -Ee
source "/opt/ros/$1/setup.bash"
cd -- "$2"
exec colcon build
' bash "${ROS_DISTRO_NAME}" "${SDK_DIR}"

echo "==> Done"
