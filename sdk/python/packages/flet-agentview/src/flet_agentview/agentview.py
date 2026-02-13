"""
AgentView - Python-side control for the AI Agent chat interface.

Custom Dart chat widget with markdown rendering, keyboard shortcuts,
and slash command popup. Replaces Syncfusion SfAIAssistView.

Communication follows the established SuperPlot pattern:
  Python → Dart: JSON string properties
  Dart → Python: FletBackend.triggerControlEvent()
"""

import json
from typing import Optional

import flet as ft


# Source version — must match Dart AgentViewControl.version
SOURCE_VERSION = '0.2.0'


@ft.control("flet_agentview")
class AgentView(ft.LayoutControl):
    """AI Agent chat view with custom Dart widget.

    Properties sent to Dart as JSON strings:
        messages: JSON array of {role, content, timestamp}
        placeholder_text: shown when no messages
        input_hint: composer hint text
        theme_bg: background color hex
        slash_commands: JSON array of {command, label, icon}

    Events received from Dart:
        on_request: user submitted a message (text in event data)
    """

    # JSON-encoded message list
    messages: Optional[str] = None

    # UI configuration
    placeholder_text: str = "What can I help you with today?"
    input_hint: str = "Ask something..."
    theme_bg: str = "#1A191F"

    # Slash command definitions for the popup menu
    slash_commands: Optional[str] = None
    """JSON array of {command, label, icon} for the slash command popup.

    Example: [{"command": "/python", "label": "Python REPL", "icon": "terminal"}]
    """

    # Whether this view is the active/visible layer (triggers input focus)
    active: bool = True

    # Agent mode label shown as a chip in the composer (e.g. "General")
    mode_label: str = ""

    # Base64-encoded icon for the current mode (shown instead of text when set)
    mode_icon: str = ""

    # Dart runtime version (sent back from Dart on mount)
    runtime_version: Optional[str] = None

    # Event: user submitted text in the composer
    on_request: Optional[ft.ControlEventHandler["AgentView"]] = None

    def add_message(self, role: str, content: str):
        """Add a message and push to Dart."""
        msgs = json.loads(self.messages) if self.messages else []
        msgs.append({"role": role, "content": content})
        self.messages = json.dumps(msgs)

    def clear_messages(self):
        """Clear all messages."""
        self.messages = json.dumps([])
