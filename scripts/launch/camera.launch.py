"""Launch the unmodified Orbbec driver with independent image processing."""

from pathlib import Path
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, GroupAction, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import SetRemap
from launch_ros.substitutions import FindPackageShare


def launch_camera(context):
    name = LaunchConfiguration("camera_name").perform(context)
    stream = LaunchConfiguration("image_stream").perform(context)
    rotation = LaunchConfiguration("image_rotation").perform(context)
    processor = str(Path(__file__).resolve().parents[1] / "process_camera_image.py")
    driver = IncludeLaunchDescription(PythonLaunchDescriptionSource(PathJoinSubstitution([
        FindPackageShare("orbbec_camera"), "launch", LaunchConfiguration("driver_launch"),
    ])))
    # Unrotated cameras keep their original publishing path; wrists only need an alias.
    if rotation == "0":
        if stream == "color":
            return [driver]
        return [GroupAction([
            SetRemap(src=f"/{name}/{stream}/image_raw/compressed",
                     dst=f"/{name}/color/image_raw/compressed"), driver,
        ])]
    image = f"/{name}/{stream}/image_raw/compressed"
    info = f"/{name}/{stream}/camera_info"
    remaps = []
    if stream == "color":
        source_image, source_info = f"/{name}/_source/image_raw/compressed", f"/{name}/_source/camera_info"
        remaps = [SetRemap(src=image, dst=source_image), SetRemap(src=info, dst=source_info)]
        image, info = source_image, source_info
    return [GroupAction([*remaps, driver]), ExecuteProcess(cmd=[
        "/usr/bin/python3", processor, "--camera-name", name, "--image-stream", stream,
        "--input-topic", image, "--camera-info-input", info,
        "--rotation", LaunchConfiguration("image_rotation"),
        "--width", LaunchConfiguration("output_width"),
        "--height", LaunchConfiguration("output_height"),
    ], output="screen")]


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument("camera_name", default_value="camera"),
        DeclareLaunchArgument("driver_launch", default_value="gemini305.launch.py"),
        DeclareLaunchArgument("image_stream", default_value="left_color"),
        DeclareLaunchArgument("image_rotation", default_value="0"),
        DeclareLaunchArgument("output_width", default_value="640"),
        DeclareLaunchArgument("output_height", default_value="480"),
        OpaqueFunction(function=launch_camera),
    ])
