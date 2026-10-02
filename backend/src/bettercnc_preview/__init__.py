"""Bounded, isolated LinuxCNC RS274 program preview (all output lengths in mm)."""

from ._parser import parse_program

__all__ = ["parse_program"]
