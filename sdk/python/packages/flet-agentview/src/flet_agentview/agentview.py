"""
AgentView - Python-side control for the AI Agent chat interface.

Uses Syncfusion's SfAIAssistView on the Dart side for rendering.
Communication follows the established SuperPlot pattern:
  Python → Dart: JSON string properties
  Dart → Python: FletBackend.updateControl()
"""

import json
from typing import Optional

import flet as ft


# Source version — must match Dart AgentViewControl.version
SOURCE_VERSION = '0.1.0'


@ft.control("flet_agentview")
class AgentView(ft.LayoutControl):
    """AI Agent chat view backed by Syncfusion SfAIAssistView.

    Properties sent to Dart as JSON strings:
        messages: JSON array of {role, content, timestamp}
        placeholder_text: shown when no messages
        input_hint: composer hint text
        theme_bg: background color hex

    Events received from Dart:
        on_request: user submitted a message (text in event data)
    """

    # JSON-encoded message list
    messages: Optional[str] = None

    # UI configuration
    placeholder_text: str = "What can I help you with today?"
    input_hint: str = "Ask something..."
    theme_bg: str = "#1A191F"

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
