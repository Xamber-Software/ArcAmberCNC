"""LinuxCNC command policy. All methods must run on one non-GUI worker thread.

Positions, increments and speeds use native machine units (speeds per second).
Overrides are ratios, spindle speed is RPM, and homed is indexed by joint.
An offline snapshot contains no coordinates. Command completion reports the NML
command result; it is never a substitute for the observed machine state.
"""

from ._controller import Controller

__all__ = ["Controller"]
