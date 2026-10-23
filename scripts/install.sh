#!/bin/bash
# Install dependencies and build the Orbbec ROS2 driver (ROS 2 Jazzy).
# Usage: ./scripts/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SDK_DIR="${REPO_DIR}/OrbbecSDK_ROS2"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [ ! -e "${SDK_DIR}/.git" ]; then
  echo "==> Fetching OrbbecSDK_ROS2 submodule"
  git -C "${REPO_DIR}" submodule update --init
fi

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
  ros-${ROS_DISTRO_NAME}-rmw-zenoh-cpp \
  ros-${ROS_DISTRO_NAME}-compressed-image-transport \
  ros-${ROS_DISTRO_NAME}-rqt-image-view

echo "==> Installing Orbbec udev rules"
$SUDO bash "${SDK_DIR}/orbbec_camera/scripts/install_udev_rules.sh"

# GMSL cameras (Gemini 335Lg) are V4L2 devices owned by the video group; the
# udev rule above only covers USB cameras.
if [ "$(id -u)" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qx video; then
  echo "==> Adding $USER to the video group for GMSL camera access"
  $SUDO usermod -aG video "$USER"
  echo "    Log out and back in before starting GMSL cameras."
fi

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
