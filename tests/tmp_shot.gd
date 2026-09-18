extends SceneTree

## Temporary diagnostic capture: loads the demo, waits a few frames, saves the
## root viewport to a PNG given by `--out=<res://...>`. Deleted after use.

var _frames := 0
var _out := "user://tmp_shot.png"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
	var packed: PackedScene = load("res://demo/demo.tscn")
	root.add_child(packed.instantiate())


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= 120:
		var image := root.get_texture().get_image()
		image.save_png(_out)
		print("SHOT %s size=%s" % [_out, str(image.get_size())])
		quit()
	return false
