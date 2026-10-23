#!/usr/bin/env python3
"""Rotate camera images and publish a fixed size without modifying the SDK."""

import argparse
import copy
from dataclasses import dataclass
import math
import time

import cv2
import numpy as np
import rclpy
from geometry_msgs.msg import TransformStamped
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CameraInfo, CompressedImage
from tf2_ros import StaticTransformBroadcaster


ROTATIONS = {90: cv2.ROTATE_90_CLOCKWISE, 180: cv2.ROTATE_180,
             270: cv2.ROTATE_90_COUNTERCLOCKWISE}


@dataclass
class Geometry:
    pixels: np.ndarray
    axes: np.ndarray
    edges: np.ndarray


def geometry(width, height, rotation, output_width=640, output_height=480):
    if min(width, height, output_width, output_height) <= 0:
        raise ValueError("Image dimensions must be positive")
    if rotation == 0:
        pixels = np.eye(3)
        edges = pixels.copy()
    elif rotation == 90:
        pixels = np.array([[0, -1, height - 1], [1, 0, 0], [0, 0, 1]], dtype=float)
        edges = pixels.copy()
        edges[0, 2] += 1
    elif rotation == 180:
        pixels = np.array([[-1, 0, width - 1], [0, -1, height - 1], [0, 0, 1]], dtype=float)
        edges = pixels.copy()
        edges[:2, 2] += 1
    elif rotation == 270:
        pixels = np.array([[0, 1, 0], [-1, 0, width - 1], [0, 0, 1]], dtype=float)
        edges = pixels.copy()
        edges[1, 2] += 1
    else:
        raise ValueError("Rotation must be 0, 90, 180 or 270")
    axes = pixels.copy()
    axes[:2, 2] = 0
    if rotation in (90, 270):
        width, height = height, width
    sx, sy = output_width / width, output_height / height
    resize = np.array([[sx, 0, (sx - 1) / 2],
                       [0, sy, (sy - 1) / 2], [0, 0, 1]])
    resize_edges = np.diag([sx, sy, 1])
    return Geometry(resize @ pixels, axes, resize_edges @ edges)


def transform_image(image, rotation, output_width=640, output_height=480):
    if rotation:
        image = cv2.rotate(image, ROTATIONS[rotation])
    if image.shape[:2] != (output_height, output_width):
        image = cv2.resize(image, (output_width, output_height), interpolation=cv2.INTER_LINEAR)
    return image


def transform_camera_info(message, rotation, output_width=640, output_height=480):
    info = copy.deepcopy(message)
    layout = geometry(info.width, info.height, rotation, output_width, output_height)
    axes4 = np.eye(4)
    axes4[:3, :3] = layout.axes
    info.k = (layout.pixels @ np.asarray(info.k).reshape(3, 3) @ layout.axes.T).ravel().tolist()
    info.r = (layout.axes @ np.asarray(info.r).reshape(3, 3) @ layout.axes.T).ravel().tolist()
    info.p = (layout.pixels @ np.asarray(info.p).reshape(3, 4) @ axes4.T).ravel().tolist()
    if info.distortion_model in ("plumb_bob", "rational_polynomial") and len(info.d) >= 4:
        tangent = layout.axes @ [info.d[3], info.d[2], 0]
        info.d[2], info.d[3] = float(tangent[1]), float(tangent[0])
    roi = info.roi
    if roi.width and roi.height:
        x, y, w, h = roi.x_offset, roi.y_offset, roi.width, roi.height
        corners = layout.edges @ np.array([[x, x + w, x, x + w],
                                           [y, y, y + h, y + h], [1, 1, 1, 1]])
        lower = np.floor(corners[:2].min(axis=1) + 0.5).astype(int)
        upper = np.floor(corners[:2].max(axis=1) + 0.5).astype(int)
        roi.x_offset, roi.y_offset = int(lower[0]), int(lower[1])
        roi.width, roi.height = int(upper[0] - lower[0]), int(upper[1] - lower[1])
    if rotation in (90, 270):
        info.binning_x, info.binning_y = info.binning_y, info.binning_x
    info.width, info.height = output_width, output_height
    if rotation:
        info.header.frame_id += "_rotated"
    return info


class CameraImageProcessor(Node):
    def __init__(self, args):
        super().__init__(f"{args.camera_name}_image_processor")
        self.args = args
        self.last_error = -math.inf
        self.tf_parent = None
        target = f"/{args.camera_name}"
        incoming = QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT)
        self.images = self.create_publisher(CompressedImage, f"{target}/color/image_raw/compressed", 1)
        self.infos = self.create_publisher(CameraInfo, f"{target}/color/camera_info", 1)
        self.broadcaster = StaticTransformBroadcaster(self)
        self.create_subscription(CompressedImage, args.input_topic, self.on_image, incoming)
        self.create_subscription(CameraInfo, args.camera_info_input, self.on_info, incoming)
        self.get_logger().info(f"rotation={args.rotation}, output={args.width}x{args.height}")

    def on_image(self, message):
        if not self.images.get_subscription_count():
            return
        try:
            image = cv2.imdecode(np.frombuffer(message.data, dtype=np.uint8), cv2.IMREAD_COLOR)
            if image is None:
                raise ValueError("Cannot decode camera image")
            if self.args.rotation == 0 and image.shape[:2] == (self.args.height, self.args.width):
                self.images.publish(message)
                return
            image = transform_image(image, self.args.rotation, self.args.width, self.args.height)
            ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 95])
            if not ok:
                raise ValueError("Cannot encode camera image")
            output = CompressedImage()
            output.header = copy.deepcopy(message.header)
            if self.args.rotation:
                output.header.frame_id += "_rotated"
            output.format = "rgb8; jpeg compressed bgr8"
            output.data = encoded.tobytes()
            self.images.publish(output)
        except (ValueError, cv2.error) as error:
            if time.monotonic() - self.last_error >= 5:
                self.get_logger().error(str(error))
                self.last_error = time.monotonic()

    def on_info(self, message):
        output = transform_camera_info(message, self.args.rotation, self.args.width, self.args.height)
        if self.args.rotation and self.tf_parent != message.header.frame_id:
            transform = TransformStamped()
            transform.header = copy.deepcopy(message.header)
            transform.child_frame_id = output.header.frame_id
            angle = -math.radians(self.args.rotation) / 2
            transform.transform.rotation.z = math.sin(angle)
            transform.transform.rotation.w = math.cos(angle)
            self.broadcaster.sendTransform(transform)
            self.tf_parent = message.header.frame_id
        self.infos.publish(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--camera-name", required=True)
    parser.add_argument("--image-stream", choices=("color", "left_color", "right_color"), required=True)
    parser.add_argument("--input-topic", required=True)
    parser.add_argument("--camera-info-input", required=True)
    parser.add_argument("--rotation", type=int, choices=(0, 90, 180, 270), default=0)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    args = parser.parse_args()
    if min(args.width, args.height) <= 0:
        parser.error("width and height must be positive")
    rclpy.init(args=[])
    node = CameraImageProcessor(args)
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, rclpy.executors.ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
