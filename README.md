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

选 **2) 启动相机**，直接进入启动流程。安装或重新编译驱动请选 **1) 安装依赖并编译**。

每选定一台相机，就立即选择该相机的图像旋转角度：`0 / 90 / 180 / 270` 度，首次回车默认 `0`，然后继续选择下一台相机。相机角色和旋转角度一起保存，下次启动的“上次保存的相机角色配置”会显示各路角度。选择 **1) 使用上次配置**（或直接回车）后，直接沿用已保存的相机位置和旋转角度启动，不再重复询问；需要修改时选 **2) 重新检测并填写相机位置**。

旋转角度通过交互提示设置；非交互启动沿用已保存的角度，旧配置没有角度时按 `0` 处理。旋转作用于原话题发布的图像，采集和订阅程序会直接收到旋转后的画面，话题名称不变。

图像处理由当前项目的 `scripts/process_camera_image.py` 完成，不修改 `OrbbecSDK_ROS2` 源码，也不改变左右目选择：左腕仍使用左目，右腕仍使用右目。先按顺时针方向旋转，再缩放到与右手一致的 `640 × 480`，三路相机输出尺寸相同。相机标定和旋转对应的光学坐标变换同步更新。修改这些脚本后重启相机即可，无需重新编译 SDK。

### 1.3 可视化

选 **3) 可视化**

启动时会将 `rqt_image_view` 自身保存的显示旋转重置为 `0°`，避免与相机配置中的角度叠加。图像方向以相机角色配置为准。

### 1.4 话题

- `/camera_left_wrist/color/image_raw/compressed`
- `/camera_right_wrist/color/image_raw/compressed`
- `/camera_head/color/image_raw/compressed`

## 2. CAN

设置腰部关节通信。选 **4) 启动 CAN**,按提示选模式(CAN FD 1M/5M 或经典 CAN 500K)和端口。
