# Camera Setup

## 1.Orbbec相机配置 
Gemini 305 左右腕相机和 Gemini 335Lg 头部相机的启动脚本。ROS2 驱动为 **2.8.7**,内置 SDK 为 **2.8.6**,官方子模块固定在 `cb24b007cd3309bc5340fa89d5082b69eba20601`。

### 1.1 获取代码

```bash
git clone --recurse-submodules git@github.com:fiveages-vla/camera_setup.git
cd camera_setup
```

已有仓库初始化子模块:

```bash
git submodule update --init
```

### 1.2 新机器安装

注意：
*1.确保 ROS2 Jazzy版本已安装*
*2.已安装
(`install.sh` 依赖 `/opt/ros/jazzy`,不会自动安装 ROS)。以下命令在 `camera_setup` 目录执行:

安装
```bash
./install.sh
./camera.sh
```

`install.sh` 依次完成:安装 apt 依赖(libusb、gflags、rosdep、colcon、rmw_zenoh、compressed_image_transport、rqt_image_view)、安装 Orbbec udev 规则、`rosdep init/update` 并安装 `OrbbecSDK_ROS2` 的 ROS 依赖。非 root 用户会自动使用 `sudo`。

安装 udev 规则后重新插拔相机。启动菜单选择 **2（首次配置 / 重新编译，然后启动）**,脚本自动配置话题映射、编译并继续启动相机。x86_64 和 arm64 均在目标机器上编译,不要复制其他机器的 `build/`、`install/`、`log/`。

### 1.3 启动和停止

```bash
./camera.sh        # 回车正常启动,帧率回车默认 30 Hz
./view.sh          # 查看画面,默认头部,下拉切换相机
./killcam.sh       # 停止相机,保留 Zenoh 路由器
```

正常使用时,启动方式直接回车,再按提示选择帧率;也可运行 `./camera.sh 30` 固定 30 Hz。首次启动按型号和序列号分配左腕、右腕、头部相机,配置会自动保存。60 Hz 为实验选项,Gemini 305 可能无法稳定出图。

`camera.sh` 和 `view.sh` 使用当前脚本所在目录的 `OrbbecSDK_ROS2`。默认通信配置为 `RMW_IMPLEMENTATION=rmw_zenoh_cpp`、`ROS_DOMAIN_ID=16`,数采进程使用相同配置。

发布的话题均为 `sensor_msgs/msg/CompressedImage`,尺寸为 `640×480`,与数采配置一致:

- `/camera_left_wrist/color/image_raw/compressed`
- `/camera_right_wrist/color/image_raw/compressed`
- `/camera_head/color/image_raw/compressed`

验证:

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp ROS_DOMAIN_ID=16
ros2 topic list | grep camera
ros2 topic hz /camera_head/color/image_raw/compressed
```

日志在 `/tmp/camera_logs/`。

## 2. CAN
设置腰部关节通信

```bash
./can.sh
```

按提示选择模式(CAN FD 1M/5M 或经典 CAN 500K)和端口即可。
