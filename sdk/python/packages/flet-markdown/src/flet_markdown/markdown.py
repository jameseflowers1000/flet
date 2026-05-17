from typing import Optional

import flet as ft


@ft.control("flet_markdown")
class EMarkdown(ft.LayoutControl):
    """Native markdown renderer using gpt_markdown.

    Supports GitHub-flavored markdown, LaTeX ($...$, $$...$$),
    code blocks with syntax highlighting, and custom colored text
    via <color=red>text</color> syntax.
    """

    value: str = ""
    code_theme: Optional[str] = "atom-one-dark"
    dark_mode: bool = True

    # Tab-navigation metadata pushed from the host Property's
    # tab_group / tab_order / tab_skip. Read by the Dart widget's
    # EpyxFocusable wrapper; controls whether this markdown panel
    # participates in Cmd-; / Tab traversal.
    tab_group: Optional[int] = None
    tab_order: Optional[int] = None
    tab_skip: bool = False
    # Logical name (e.g., 'inkpad2') for diagnostics + Python-side
    # focus reporting.
    tab_name: str = ""
