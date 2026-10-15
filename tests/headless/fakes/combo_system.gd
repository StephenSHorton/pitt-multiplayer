extends Node
## Headless fake of ComboSystem. combo_updated is declared with 3 args but, like
## the game, emitted with 2.

signal combo_started(combo_level)
signal combo_updated(combo_level, time_remaining, next_bonus)
signal combo_ended(combo_level, total_bonus)
signal combo_broken
signal mega_combo_activated(multiplier)
