import json

import flet as ft
from flet_supertab import SuperTab


async def main(page: ft.Page):
    page.title = "Supertab grid (editable)"

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

    # Status text to show edit events
    status = ft.Text("Double-click a cell to edit, press Enter to commit")

    def on_cell_edit(e):
        # e.data is JSON: {"row_index", "column_name", "old_value", "new_value"}
        data = json.loads(e.data)
        status.value = (
            f"Edited row {data['row_index']}, column '{data['column_name']}': "
            f"'{data['old_value']}' → '{data['new_value']}'"
        )
        page.update()

    grid = SuperTab(
        columns=columns,
        rows=rows,
        editable=True,
        on_cell_edit=on_cell_edit,
    )

    page.add(status, grid)


ft.run(main)
