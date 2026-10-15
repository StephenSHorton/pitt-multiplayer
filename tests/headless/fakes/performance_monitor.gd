extends Node
## Headless fake of PerformanceMonitor.

func get_current_tick_rate() -> int:
	return int(Engine.get_physics_ticks_per_second())
