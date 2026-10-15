extends CanvasLayer
## Stand-in for the game's end_of_game.gd menu (only what the adapter checks).

func show_end_game(_secret: bool = false) -> void:
	show()
