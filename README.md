# Camera Setup

目前脚本仅适配 **Orbbec** 摄像头(Gemini 305 / 330 系列),另含 CAN 启动脚本(ROS 2 Jazzy,x86_64 / arm64 均可)。

- `OrbbecSDK_ROS2/`:官方 SDK(submodule,`v2.7.6`)
- `camera.sh`:启动相机
- `killcam.sh`:停止相机
- `can.sh`:启动 CAN

## 获取代码

```bash
git clone --recurse-submodules git@github.com:fiveages-vla/camera_setup.git
# 已 clone 的:git submodule update --init
```


## Orbbec

### 1. 安装(只需一次)

```bash
sudo apt install -y libusb-1.0-0-dev libgflags-dev git python3-rosdep

# udev 规则,装完重新插拔相机
cd OrbbecSDK_ROS2/orbbec_camera/scripts
sudo bash install_udev_rules.sh
sudo udevadm control --reload-rules && sudo udevadm trigger

# 编译 SDK
cd ../..
source /opt/ros/jazzy/setup.bash   # 需提前安装运控(提供 ROS 2 Jazzy)
sudo rosdep init 2>/dev/null || true   # 已初始化过会报错,忽略
rosdep update
rosdep install --from-paths . --ignore-src -r -y
colcon build
```

x86_64 与 arm64 步骤相同,但编译产物与架构绑定:换机器架构后需重新编译,不要拷贝 `build/`、`install/`、`log/`。

### 2. 启动相机

```bash
./camera.sh        # 交互选择 30 / 60 Hz
```

按提示选择左腕 / 右腕 / 头部对应的相机序列号,选择会被记住。启动后发布:

- `/camera_left_wrist/color/image_raw/compressed`
- `/camera_right_wrist/color/image_raw/compressed`
- `/camera_head/color/image_raw/compressed`

验证(新开终端):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp ROS_DOMAIN_ID=16   # 与 camera.sh 保持一致

ros2 topic list | grep camera
ros2 topic hz /camera_head/color/image_raw/compressed
```

`topic list` 应能看到上述话题,`topic hz` 的频率应接近所选帧率。

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
