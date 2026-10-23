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

选 **2) 启动相机**(需要重新编译时选「首次配置 / 重新编译」)

分配每台相机的位置(左腕/右腕/头部)时,会接着选择该相机的画面旋转角度(0/90/180/270),和相机位置一起保存到 `~/.config/camera_setup/camera_roles.conf`。
下次启动选「使用上次配置」会沿用;安装位置变化时选「重新检测并填写相机位置」,角度会以上次的值为默认。

旋转在相机设备端完成,角度为 90/270 时会把请求的分辨率从 640×480 换成 480×640,所以各路画面的实际宽高会随各自的角度而不同。

日志、PID 文件和运行时生成的配置都放在当前用户的私有目录 `$XDG_RUNTIME_DIR/camera_setup-<uid>/`(没有 `XDG_RUNTIME_DIR` 时是 `/tmp/camera_setup-<uid>/`),权限 700,日志在其中的 `logs/` 下。

### 1.3 可视化

选 **3) 可视化**

### 1.4 话题

- `/camera_left_wrist/left_color/image_raw/compressed`
- `/camera_right_wrist/right_color/image_raw/compressed`
- `/camera_head/color/image_raw/compressed`

## 2. CAN

设置腰部关节通信。选 **4) 启动 CAN**,按提示选模式(CAN FD 1M/5M 或经典 CAN 500K)和端口。

## 3. 测试

不需要相机和 ROS,可以离线运行:

```bash
tests/run_tests.sh
```
