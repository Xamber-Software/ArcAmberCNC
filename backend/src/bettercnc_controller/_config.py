"""Read configuration through the LinuxCNC INI API, including #INCLUDE support."""

import math
import os
import re

AXES = "XYZABCUVW"
SYSTEMS = ("G54", "G55", "G56", "G57", "G58", "G59", "G59.1", "G59.2", "G59.3")


class Configuration:
    def __init__(self, module, path):
        self.path = os.path.realpath(os.path.expanduser(path)) if path else None
        self.ini = module.ini(self.path) if self.path else None
        self.no_force_homing = self.get("TRAJ", "NO_FORCE_HOMING") == "1"
        self.joints = int(self.number("KINS", "JOINTS", 0))
        self.joint_map = {}
        kinematics = self.get("KINS", "KINEMATICS") or ""
        # Only trivkins defines a known Cartesian-to-joint mapping. A Cartesian
        # axis name is never used as a guessed joint index for other kinematics.
        if kinematics.split()[:1] == ["trivkins"]:
            match = re.search(r"(?:^|\s)coordinates=([XYZABCUVWxyzabcuvw]+)(?:\s|$)", kinematics)
            # This is trivkins' documented default, not TRAJ COORDINATES order.
            coordinates = match.group(1).upper() if match else AXES
            if 0 < self.joints <= len(coordinates):
                for joint, axis in enumerate(coordinates[: self.joints]):
                    self.joint_map.setdefault(axis, []).append(joint)
        self.max_velocity = self.number("TRAJ", "MAX_LINEAR_VELOCITY")
        self.jog_max_velocity = self.number("DISPLAY", "MAX_LINEAR_VELOCITY", self.max_velocity)
        self.feed_max = self.number("DISPLAY", "MAX_FEED_OVERRIDE", 1.0)
        self.spindle_override_min = self.number("DISPLAY", "MIN_SPINDLE_OVERRIDE", 0.0)
        self.spindle_override_max = self.number("DISPLAY", "MAX_SPINDLE_OVERRIDE", 1.0)
        self.spindle_min = self.number("SPINDLE_0", "MIN_FORWARD_VELOCITY", 0.0)
        self.spindle_max = self.number("SPINDLE_0", "MAX_FORWARD_VELOCITY")
        self.spindle_min = self.number(
            "DISPLAY",
            "MIN_SPINDLE_SPEED",
            self.number("DISPLAY", "MIN_SPINDLE_0_SPEED", self.spindle_min),
        )
        self.spindle_max = self.number(
            "DISPLAY",
            "MAX_SPINDLE_SPEED",
            self.number("DISPLAY", "MAX_SPINDLE_0_SPEED", self.spindle_max),
        )
        self.default_spindle = self.number(
            "DISPLAY", "DEFAULT_SPINDLE_SPEED", self.number("DISPLAY", "DEFAULT_SPINDLE_0_SPEED")
        )
        self.axis_limits = {}
        self.joint_limits = {}
        self.home_sequences = {}
        for axis in AXES:
            section = "AXIS_" + axis
            self.axis_limits[axis] = {
                "min": self.number(section, "MIN_LIMIT"),
                "max": self.number(section, "MAX_LIMIT"),
                "maxVelocity": self.number(section, "MAX_VELOCITY"),
            }
        for joint in range(self.joints):
            section = "JOINT_" + str(joint)
            self.joint_limits[joint] = self.number(section, "MAX_VELOCITY")
            self.home_sequences[joint] = self.number(section, "HOME_SEQUENCE")

    def get(self, section, key):
        return self.ini.find(section, key) if self.ini else None

    def number(self, section, key, default=None):
        value = self.get(section, key)
        if value is None:
            return default
        result = float(value)
        if not math.isfinite(result):
            raise ValueError(f"INI [{section}] {key} must be finite")
        return result

    def file(self, section, key):
        value = self.get(section, key)
        if not value:
            return None
        value = os.path.expanduser(os.path.expandvars(value))
        if not os.path.isabs(value):
            value = os.path.join(os.path.dirname(self.path), value)
        return os.path.realpath(value)

    def snapshot(self):
        return {
            "iniPath": self.path,
            "parameterFile": self.file("RS274NGC", "PARAMETER_FILE"),
            "toolTablePath": self.file("EMCIO", "TOOL_TABLE"),
            "programPrefix": self.file("DISPLAY", "PROGRAM_PREFIX"),
            "pyvcpPath": self.file("DISPLAY", "PYVCP"),
            "defaultSpindleSpeed": self.default_spindle,
            "spindleMin": self.spindle_min,
            "spindleMax": self.spindle_max,
            "maxVelocityLimit": self.max_velocity,
            "jogMaxVelocity": self.jog_max_velocity,
            "jointMap": self.joint_map,
            "axisLimits": self.axis_limits,
            "noForceHoming": self.no_force_homing,
            "randomToolChanger": self.get("EMCIO", "RANDOM_TOOLCHANGER") == "1",
            "feedOverrideMax": self.feed_max,
            "spindleOverrideMin": self.spindle_override_min,
            "spindleOverrideMax": self.spindle_override_max,
        }
