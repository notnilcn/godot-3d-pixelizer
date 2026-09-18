// Pixelizer3D bridge compatibility header.
//
// The native macro header is `anchor_macros.gdshaderinc` (ANCHOR_* entry
// points). The editor-time shader bridge injects the PIXELIZER_* vocabulary and
// includes the native header; this file exists so an external shader can also
// opt in under the historical `pixelizer_macros.gdshaderinc` name.
//
// It does NOT define any macros itself (that would duplicate the header); it
// only forwards to the single source of truth. When a bridge-generated shader
// owns its own cloud toolkit it defines `PIXELIZER_NO_CLOUD` before including
// either header, which compiles out the bundled `cloud_fbm.gdshaderinc` and
// `anchor_grade()` (see anchor_macros.gdshaderinc).
//
// Shader comments are `//` only in Godot, so this file must not use `##`.

#ifndef PIXELIZER_MACROS_BRIDGE_INC
#define PIXELIZER_MACROS_BRIDGE_INC

#include "res://addons/pixelizer_3d/shaders/anchor_macros.gdshaderinc"

#endif
