"""Launch the stock Gemini305 driver, exposing only one colour eye as color/*.

The SDK launch file publishes left_color/* and right_color/*. This wrapper
remaps the selected eye to color/* and the other eye to hidden (_-prefixed)
names, so the SDK source stays untouched.
"""
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument,
    GroupAction,
    IncludeLaunchDescription,
    OpaqueFunction,
)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import SetRemap
from launch_ros.substitutions import FindPackageShare

FORWARDED_ARGS = ("camera_name", "serial_number", "usb_port", "config_file_path")
COMMON_HIDDEN = (
    ("device_status", "_device_status"),
    ("depth_filter_status", "_depth_filter_status"),
    ("depth_filters/status", "_depth_filters/status"),
)
EYE_TOPICS = ("image_raw", "image_raw/compressed", "camera_info", "metadata")


def remap_rules(selected, other):
    rules = []
    for topic in EYE_TOPICS:
        shown = {
            "camera_info": "_camera_info",
            "metadata": "_metadata",
        }.get(topic, f"color/{topic}")
        rules.append((f"{selected}_color/{topic}", shown))
        rules.append((f"{other}_color/{topic}", f"_{other}_color/{topic}"))
    return rules + list(COMMON_HIDDEN)


def build_group(context):
    eye = LaunchConfiguration("selected_color_eye").perform(context)
    if eye not in ("left", "right"):
        raise RuntimeError(f"selected_color_eye must be left or right, got {eye!r}")
    other = "right" if eye == "left" else "left"

    sdk_launch = PathJoinSubstitution(
        [FindPackageShare("orbbec_camera"), "launch", "gemini305.launch.py"]
    )
    include = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(sdk_launch),
        launch_arguments={name: LaunchConfiguration(name) for name in FORWARDED_ARGS}.items(),
    )
    remaps = [SetRemap(src=src, dst=dst) for src, dst in remap_rules(eye, other)]
    return [GroupAction(remaps + [include])]


def generate_launch_description():
    args = [DeclareLaunchArgument(name) for name in FORWARDED_ARGS]
    args.append(DeclareLaunchArgument("selected_color_eye"))
    return LaunchDescription(args + [OpaqueFunction(function=build_group)])
