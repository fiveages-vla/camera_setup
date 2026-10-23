"""Start one Gemini 305 wrist camera and publish its single eye under <camera_name>/color.
Includes the unmodified gemini305.launch.py and passes every other launch argument through;
only the topic names are remapped."""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, GroupAction, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import SetRemap
from launch_ros.substitutions import FindPackageShare


def launch_wrist(context):
    name = LaunchConfiguration("camera_name").perform(context)
    eye = LaunchConfiguration("eye").perform(context)
    if eye not in ("left", "right"):
        raise ValueError(f"eye must be left or right, got {eye!r}")
    driver = IncludeLaunchDescription(PythonLaunchDescriptionSource(PathJoinSubstitution([
        FindPackageShare("orbbec_camera"), "launch", "gemini305.launch.py",
    ])))
    return [GroupAction([
        SetRemap(src=f"/{name}/{eye}_color/image_raw/compressed", dst=f"/{name}/color/image_raw/compressed"),
        SetRemap(src=f"/{name}/{eye}_color/camera_info", dst=f"/{name}/color/camera_info"),
        driver,
    ])]


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument("camera_name", default_value="camera"),
        DeclareLaunchArgument("eye", default_value="left", description="left or right"),
        OpaqueFunction(function=launch_wrist),
    ])
