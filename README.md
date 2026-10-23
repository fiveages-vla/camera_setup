# Camera Setup

```bash
git clone --recurse-submodules git@github.com:fiveages-vla/camera_setup.git
# 已下载代码但 OrbbecSDK_ROS2 目录为空:git submodule update --init
```

所有操作从 `./quick_start.sh` 菜单进入:

```
camera_setup# ./quick_start.sh
Camera quick start
  1) 安装依赖并编译    (scripts/install.sh)
  2) 启动相机    (scripts/camera.sh)
  3) 可视化      (scripts/view.sh)
  4) 启动 CAN    (scripts/can.sh)
  5) 停止相机    (scripts/killcam.sh)
  q) 退出
请选择 [1-5/q]:
```

## 1. Orbbec 相机

Gemini 305 左右腕相机 + Gemini 335Lg 头部相机。OrbbecSDK_ROS2版本v2.8.7

### 1.1 安装

1. 确保已安装 ROS 2 Jazzy
2. 安装并编译 Orbbec SDK:选 **1) 安装依赖并编译**

### 1.2 启动

选 **2) 启动相机**,直接进入帧率选择和设备扫描。安装或重新编译驱动请选 **1) 安装依赖并编译**。

分配每台相机的位置(左腕/右腕/头部)时,会接着选择该相机的画面旋转角度(0/90/180/270),和相机位置一起保存到 `~/.config/camera_setup/camera_roles.conf`。
下次启动选「使用上次配置」会沿用;安装位置变化时选「重新检测并填写相机位置」,角度会以上次的值为默认。

旋转由 Orbbec SDK 的帧处理器在驱动内完成,相机标定(`camera_info`)随之同步变换,脚本不做额外处理。两个前提是实测得出的:

- 必须使用非压缩格式(YUYV)。MJPG 压缩帧无法被 SDK 旋转,设了角度也只会原样输出。
- 分辨率必须按传感器原生的 640×480 请求;旋转 90/270 后发布出来的画面自然变成 480×640。请求 480×640 会找不到 profile 导致驱动退出。

腕部由 `resources/launch/wrist.launch.py` 启动:它原样包含 SDK 的 `gemini305.launch.py`,只把所用那只眼的 `left_color`/`right_color` 话题重映射到 `color`,因此左右腕对外都是 `/camera_*_wrist/color/...`。腕部 Gemini 305 的驱动参数只能通过 yaml 传入,`resources/config/gemini305_left_wrist.yaml` 和 `gemini305_right_wrist.yaml` 按所用的眼区分,与左右腕无关:旋转 0°/180° 时左右腕都用右目,90°/270° 时都用左目。角度为 0 且 30 Hz 时直接使用仓库里的文件;其他角度或 60 Hz 时,脚本只改 `*_color_rotation`/`*_color_fps` 两个键,把副本写到运行时目录。序列号、USB 口、曝光、增益、白平衡以命令行参数传入(yaml 里的值会覆盖命令行,所以这些键不出现在 yaml 中)。

头部 335Lg 若以 USB 2 连接,YUYV 60 Hz 可能超出带宽,脚本会给出提示;需要 60 Hz 时请接 USB 3 口。

日志、PID 文件和运行时生成的配置都放在当前用户的私有目录 `$XDG_RUNTIME_DIR/camera_setup-<uid>/`(没有 `XDG_RUNTIME_DIR` 时是 `/tmp/camera_setup-<uid>/`),权限 700,日志在其中的 `logs/` 下。

### 1.3 可视化

选 **3) 可视化**

### 1.4 话题

- `/camera_left_wrist/color/image_raw/compressed`
- `/camera_right_wrist/color/image_raw/compressed`
- `/camera_head/color/image_raw/compressed`

对应的标定在同一前缀下的 `camera_info`。

启动时已关闭 `/tf` 和 `/diagnostics`,深度、红外、IMU、点云、外参默认关闭。驱动本身无法关闭的 `image_raw`(未压缩原图)、`camera_info`、`device_status` 仍会存在于 `ros2 topic list`。

话题名与旋转角度无关。旋转 90/270 的那一路画面为 480×640,其余为 640×480。

### 1.5 GMSL 相机

头部 Gemini 335Lg 既可以走 USB,也可以走 GMSL2,启动流程相同;设备扫描会在"连接"一栏显示 `USB3.x` 或 `GMSL2`。GMSL 前提:Jetson 上已安装 Orbbec 提供的 GMSL2 驱动(本仓库不包含),当前用户在 `video` 组内(**1) 安装依赖并编译** 会自动加入,需重新登录生效)。只接 GMSL 相机、没有任何 USB 相机时也能正常启动。

## 2. CAN

设置腰部关节通信。选 **4) 启动 CAN**,按提示选模式(CAN FD 1M/5M 或经典 CAN 500K)和端口。

