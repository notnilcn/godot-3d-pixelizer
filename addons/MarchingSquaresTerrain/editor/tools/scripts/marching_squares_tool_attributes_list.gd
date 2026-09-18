extends Resource
class_name MarchingSquaresToolAttributesList


var brush_type : Dictionary = {
	"name": "brush_type",
	"type": "option",
	"label": "Brush Type",
	"options": ["Round", "Square"],
	"default": 0,
}

var size : Dictionary = {
	"name": "size",
	"type": "slider",
	"label": "Size",
	"range": Vector3(1.0, 50.0, 0.5),
	"default": 15.0,
}

var ease_value : Dictionary = {
	"name": "ease_value",
	"type": "slider",
	"label": "Ease Value",
	"range": Vector3(-5.0, 5.0, 0.1),
	"default": -1.0, # No ease
}

var height : Dictionary = {
	"name": "height",
	"type": "slider",
	"label": "Height",
	"range": Vector3(0.0, 16.0, 1.0),
	"default": 0.0,
}

var strength : Dictionary = {
	"name": "strength",
	"type": "slider",
	"label": "Strength",
	"range": Vector3(0.025, 0.3, 0.005),
	"default": 0.05,
}

var flatten : Dictionary = {
	"name": "flatten",
	"type": "checkbox",
	"label": "Flatten",
	"default": false,
}

var falloff : Dictionary = {
	"name": "falloff",
	"type": "checkbox",
	"label": "Falloff",
	"default": true,
}

var mask_mode : Dictionary = {
	"name": "mask_mode",
	"type": "checkbox",
	"label": "Mask Mode",
	"default": true,
}

var vp_tex_names : MarchingSquaresTextureNames = preload("uid://dd7fens03aosa")

var material : Dictionary = {
	"name": "material",
	"type": "option",
	"label": "Material",
	"options": vp_tex_names.texture_names,
	"default": 0,
}

var texture_name : Dictionary = {
	"name": "texture_name",
	"type": "text",
	"label": "Texture Name",
	"default": "New name here...",
}

var texture_preset : Dictionary = {
	"name": "texture_preset",
	"type": "preset",
	"label": "Texture Preset",
	"default": null,
}

var quick_paint_selection : Dictionary = {
	"name": "quick_paint_selection",
	"type": "quick_paint",
	"label": "Quick Paint",
	"default": null,
}

var paint_walls : Dictionary = {
	"name": "paint_walls",
	"type": "checkbox",
	"label": "Paint Walls",
	"default": false,
}

var paint_mode : Dictionary = {
	"name": "paint_mode",
	"type": "option",
	"label": "Paint Mode",
	"options": ["Ground", "Walls", "Transitions"],
	"default": 0,
}

var transition_kind : Dictionary = {
	"name": "transition_kind",
	"type": "option",
	"label": "Transition",
	"options": ["Default", "Cliff", "Terrace", "Slope"],
	"default": 0,
}

var chunk_management : Dictionary = {
	"name": "chunk_management",
	"type": "chunk",
	"label": "Chunk Management",
}

var terrain_settings : Dictionary = {
	"name": "terrain_settings",
	"type": "terrain",
	"label": "Terrain Settings",
}

var export_path : Dictionary = {
	"name": "export_path",
	"type": "text",
	"label": "Export Path",
	"default": "res://terrain_export.json",
}

var import_path : Dictionary = {
	"name": "import_path",
	"type": "text",
	"label": "Import Path",
	"default": "res://terrain_export.json",
}

var export_button : Dictionary = {
	"name": "export_button",
	"type": "button",
	"label": "Export",
}

var import_button : Dictionary = {
	"name": "import_button",
	"type": "button",
	"label": "Import",
}

"""
# Example Attribute Entries
	"name": "",
	"type": "",
	"label": "",
	"range": Vector3(1.0, 50.0, 0.5),
	"options": ["Grass", "Sand", "Rock"],
	"default": 10.0,
"""
