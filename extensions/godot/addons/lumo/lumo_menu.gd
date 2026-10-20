@tool
extends EditorContextMenuPlugin
## "Ask Lumo about this" in the script editor's right-click menu and in the scene tree's.

var on_ask: Callable
var icon: Texture2D


func _popup_menu(_paths: PackedStringArray) -> void:
	add_context_menu_item("Ask Lumo about this", func(_target: Variant) -> void: on_ask.call(), icon)
