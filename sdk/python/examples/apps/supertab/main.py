import flet as ft
from flet_supertab import SuperTab


async def main(page: ft.Page):
    page.title = "Supertab grid"

    columns = [
        {"name": "id", "label": "ID", "alignment": "centerRight"},
        {"name": "name", "label": "Name", "alignment": "centerLeft"},
        {"name": "role", "label": "Role", "alignment": "centerLeft"},
    ]

    rows = [
        [10001, "James", "Project Lead"],
        [10002, "Kathryn", "Manager"],
        [10003, "Lara", "Developer"],
    ]

    grid = SuperTab(columns=columns, rows=rows)
    page.add(grid)


ft.run(main)
