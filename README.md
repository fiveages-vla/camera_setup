# Camera Setup


- `OrbbecSDK_ROS2/`:官方 ROS2 驱动(submodule,固定提交 `cb24b007cd3309bc5340fa89d5082b69eba20601`;驱动 `2.8.7`,内置 SDK `2.8.6`)
- `camera.sh`:启动相机
- `killcam.sh`:停止相机
- `can.sh`:启动 CAN

## 获取代码

```bash
git clone --recurse-submodules git@github.com:fiveages-vla/camera_setup.git
cd camera_setup
# 已 clone 的:在 camera_setup 目录执行 git submodule update --init
# 应用本机原仓库的话题映射等改动;已应用时跳过
git -C OrbbecSDK_ROS2 apply --reverse --check ../patches/orbbec-local.patch 2>/dev/null || \
  git -C OrbbecSDK_ROS2 apply ../patches/orbbec-local.patch
```

`patches/orbbec-local.patch` 保存了本机原仓库的 3 处改动,包括 Gemini 305 左右目映射到统一的 `color/image_raw` 话题。`camera.sh` 的 `selected_color_eye` 参数依赖此补丁;首次获取或重新检出子模块后,先应用补丁再编译。当前工作区已应用。

`camera.sh` 和 `view.sh` 固定使用脚本所在目录的 `OrbbecSDK_ROS2/`,不接受 `ORBBEC_WS` 环境变量覆盖。ROS 2 Jazzy 本身仍使用 `/opt/ros/jazzy`。

## Orbbec

目前脚本仅适配 **Orbbec** 摄像头(Gemini 305 / 330 系列)

### 1. 安装(只需一次)

```bash
sudo apt install -y libusb-1.0-0-dev libgflags-dev git python3-rosdep

# udev 规则,装完重新插拔相机
cd OrbbecSDK_ROS2/orbbec_camera/scripts
sudo bash install_udev_rules.sh
sudo udevadm control --reload-rules && sudo udevadm trigger

# 安装 ROS 依赖
cd ../..
source /opt/ros/jazzy/setup.bash   # 需提前安装运控(提供 ROS 2 Jazzy)
sudo rosdep init 2>/dev/null || true   # 已初始化过会报错,忽略
rosdep update
rosdep install --from-paths . --ignore-src -r -y

# 在当前 OrbbecSDK_ROS2 目录编译,避免加载其他工作区
env -i HOME="$HOME" LANG="${LANG:-C.UTF-8}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  bash --noprofile --norc -c 'source /opt/ros/jazzy/setup.bash && colcon build'
cd ..   # 返回 camera_setup
```

x86_64 与 arm64 步骤相同,但编译产物与架构绑定:换机器架构后需重新编译,不要拷贝 `build/`、`install/`、`log/`。

### 2. 启动相机

```bash
./camera.sh        # 交互选择 30 / 60 Hz
```

相机型号:头部为 Gemini 335Lg,左右腕部为 Gemini 305。按提示选择左腕 / 右腕 / 头部对应的相机序列号,选择会被记住。启动后发布:

- `/camera_left_wrist/color/image_raw/compressed`(腕部,Gemini 305)
- `/camera_right_wrist/color/image_raw/compressed`(腕部,Gemini 305)
- `/camera_head/color/image_raw/compressed`(头部,Gemini 335Lg)

验证(新开终端):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp ROS_DOMAIN_ID=16   # 与 camera.sh 保持一致

ros2 topic list | grep camera
ros2 topic hz /camera_head/color/image_raw/compressed
```

`topic list` 应能看到上述话题,`topic hz` 的频率应接近所选帧率。

查看画面(需要图形界面,依赖 `ros-jazzy-rqt-image-view`):

```bash
./view.sh          # 打开一个窗口,默认显示 head,通过下拉菜单切换相机
```

停止:

```bash
./killcam.sh
```

日志在 `/tmp/camera_logs/`。

## 启动 CAN(使用腰关节时需要)

```bash
./can.sh
```

按提示选择模式(CAN FD 1M/5M 或经典 CAN 500K)和端口即可。
