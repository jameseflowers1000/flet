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
