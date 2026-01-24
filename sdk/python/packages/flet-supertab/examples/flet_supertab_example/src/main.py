import flet as ft

from flet_supertab import SuperTab


def main(page: ft.Page):
    page.vertical_alignment = ft.MainAxisAlignment.CENTER
    page.horizontal_alignment = ft.CrossAxisAlignment.CENTER

    page.add(

                ft.Container(height=150, width=300, alignment = ft.Alignment.CENTER, bgcolor=ft.Colors.PURPLE_200, content=SuperTab(
                    tooltip="My new SuperTab Control tooltip",
                    value = "My new SuperTab Flet Control", 
                ),),

    )


ft.run(main)
