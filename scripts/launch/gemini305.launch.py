"""Rename wrist compressed image topics while using the upstream launch."""

from launch import LaunchDescription
from launch.actions import GroupAction, IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import PathJoinSubstitution
from launch_ros.actions import SetRemap
from launch_ros.substitutions import FindPackageShare


def generate_launch_description():
    return LaunchDescription([GroupAction([
        SetRemap(
            src="/camera_left_wrist/left_color/image_raw/compressed",
            dst="/camera_left_wrist/color/image_raw/compressed",
        ),
        SetRemap(
            src="/camera_right_wrist/right_color/image_raw/compressed",
            dst="/camera_right_wrist/color/image_raw/compressed",
        ),
        IncludeLaunchDescription(PythonLaunchDescriptionSource(PathJoinSubstitution([
            FindPackageShare("orbbec_camera"), "launch", "gemini305.launch.py",
        ]))),
    ])])
