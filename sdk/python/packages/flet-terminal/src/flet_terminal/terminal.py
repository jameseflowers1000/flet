"""
TerminalView - Python-side control for the SSH terminal.

Uses xterm (Dart) + dartssh2 on the Dart side.
Desktop: direct TCP SSH to container:22
Web: WebSocket via websockify to container:8551 → TCP:22

Communication follows the established SuperPlot/AgentView pattern:
  Python → Dart: JSON string properties
  Dart → Python: FletBackend.triggerControlEvent()
"""

from typing import Optional

import flet as ft


SOURCE_VERSION = '0.1.0'


@ft.control("flet_terminal")
class TerminalView(ft.LayoutControl):
    """SSH terminal view backed by xterm + dartssh2.

    Properties sent to Dart:
        ssh_host: SSH server hostname (default "localhost")
        ssh_port: direct TCP port for desktop clients
        ws_port: websockify port for web clients
        ssh_user: SSH username
        ssh_private_key: ed25519 PEM private key string
        font_size: terminal font size
        theme_bg: background color hex

    Events received from Dart:
        on_connected: SSH session established
        on_disconnected: SSH session closed
        on_error: connection or session error (error message in event data)
    """

    ssh_host: str = "localhost"
    ssh_port: int = 22
    ws_port: int = 8551
    ssh_user: str = "appuser"
    ssh_private_key: Optional[str] = None
    font_size: int = 13
    theme_bg: str = "#1A191F"

    # Dart runtime version (sent back from Dart on mount)
    runtime_version: Optional[str] = None

    # Events
    on_connected: Optional[ft.ControlEventHandler["TerminalView"]] = None
    on_disconnected: Optional[ft.ControlEventHandler["TerminalView"]] = None
    on_error: Optional[ft.ControlEventHandler["TerminalView"]] = None
