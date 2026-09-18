class_name PixelizerGlobals
extends RefCounted

## Pipeline-wide global shader uniforms. These are the parameters every pixelizer
## material shares (metadata layer bit, low-res flag, palette LUT/grading/dither,
## render screen size); per-material pushes would mean touching every registered
## material on each change. Third-party `cloud_*` uniforms deliberately stay
## material-level (see the cloud contract) because external shaders declare their
## own copies.
##
## IMPORTANT:
## - Always call `ensure()` (or `set_param()`, which calls it) before setting a
##   value: `global_shader_parameter_set` on an unregistered name logs an engine
##   error.
## - NEVER call `RenderingServer.global_shader_parameter_get()`: at runtime it
##   logs "should never be used outside the editor" and returns null.
## - `ensure()` is a no-op under the dummy renderer (headless / editor without a
##   RenderingDevice), so callers never have to guard for it.

const META_BIT := &"pixelizer_meta_bit"
const LOWRES_MODE := &"pixelizer_lowres_mode"
const PALETTE_LUT := &"pixelizer_palette_lut"
const PALETTE_GRADING := &"pixelizer_palette_grading_enabled"
const PALETTE_DITHER := &"pixelizer_palette_dither_enabled"
const SCREEN_SIZE := &"pixelizer_screen_size"

const GLOBALS := {
	META_BIT: RenderingServer.GLOBAL_VAR_TYPE_UINT,
	LOWRES_MODE: RenderingServer.GLOBAL_VAR_TYPE_BOOL,
	PALETTE_LUT: RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D,
	PALETTE_GRADING: RenderingServer.GLOBAL_VAR_TYPE_BOOL,
	PALETTE_DITHER: RenderingServer.GLOBAL_VAR_TYPE_BOOL,
	SCREEN_SIZE: RenderingServer.GLOBAL_VAR_TYPE_VEC2,
}

## Names registered this process. `global_shader_parameter_add` errors on a
## duplicate name, and a runtime add does not touch ProjectSettings, so both this
## guard and the ProjectSettings check are needed.
static var _registered: Dictionary = {}


static func ensure() -> void:
	if RenderingServer.get_rendering_device() == null:
		return
	for name in GLOBALS:
		if _registered.has(name):
			continue
		if ProjectSettings.has_setting("shader_globals/" + String(name)):
			_registered[name] = true
			continue
		RenderingServer.global_shader_parameter_add(name, GLOBALS[name], null)
		_registered[name] = true


static func set_param(name: StringName, value: Variant) -> void:
	ensure()
	RenderingServer.global_shader_parameter_set(name, value)
