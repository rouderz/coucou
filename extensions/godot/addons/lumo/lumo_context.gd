@tool
extends RefCounted
## What the user is working on in the Godot editor, in the shape Lumo's editor bridge reads:
## the file, the project, the cursor and selection, the script's errors, and as `details` the
## open scene, its tree and the selected nodes. On "Ask Lumo" also a snapshot of the editor.

const MAX_SELECTION := 8_000
const MAX_TREE_NODES := 150
const MAX_TREE_DEPTH := 8
const MAX_PROPERTIES := 40
const MAX_VALUE := 160
const MAX_DETAILS := 11_000
const MAX_SNAPSHOT_WIDTH := 1600


## Everything for one message. `main_screen` is "2D", "3D", "Script", "Game", "AssetLib"…
static func gather(main_screen: String, with_snapshot: bool) -> Dictionary:
	var project := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var script_editor := EditorInterface.get_script_editor()
	var script: Script = script_editor.get_current_script() if script_editor else null
	var root := EditorInterface.get_edited_scene_root()

	var payload := {
		"appName": "Godot",
		"workspace": project,
	}

	# The file: the script when the user is in the Script screen (or there's no scene),
	# else the open scene, else the project file.
	var code := _current_code_edit()
	var in_script := script != null and not script.resource_path.is_empty() \
		and (main_screen == "Script" or root == null)
	if in_script:
		payload["file"] = ProjectSettings.globalize_path(script.resource_path)
		payload["language"] = _language(script.resource_path)
		if code:
			payload["line"] = code.get_caret_line() + 1
			var selection := code.get_selected_text()
			if selection.length() > MAX_SELECTION:
				selection = selection.substr(0, MAX_SELECTION)
			if not selection.strip_edges().is_empty():
				payload["selection"] = selection
			var problems := _script_problems(code)
			if not problems.is_empty():
				payload["diagnostics"] = problems
	elif root and not root.scene_file_path.is_empty():
		payload["file"] = ProjectSettings.globalize_path(root.scene_file_path)
		payload["language"] = "godot-scene"
	else:
		payload["file"] = project.path_join("project.godot")
		payload["language"] = "godot-project"

	var details := _details(main_screen, root, script)
	if details.length() > MAX_DETAILS:
		details = details.substr(0, MAX_DETAILS) + "\n…"
	payload["details"] = details

	if with_snapshot:
		var image_path := _snapshot()
		if not image_path.is_empty():
			payload["image"] = image_path
	return payload


## The CodeEdit of the script in front, if any.
static func _current_code_edit() -> CodeEdit:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return null
	var current := script_editor.get_current_editor()
	if current == null:
		return null
	return current.get_base_editor() as CodeEdit


static func _language(path: String) -> String:
	match path.get_extension().to_lower():
		"gd": return "gdscript"
		"cs": return "csharp"
		"gdshader": return "gdshader"
		_: return path.get_extension().to_lower()


## The script editor shows its errors and warnings in its own panels: read them back. Best effort —
## Godot has no API for it — and lines without a number are skipped.
static func _script_problems(code: CodeEdit) -> Array:
	var problems: Array = []
	var editor := EditorInterface.get_script_editor().get_current_editor()
	if editor == null:
		return problems
	var seen := {}
	var line_number := RegEx.create_from_string("(\\d+)")
	var warning_code := RegEx.create_from_string("\\(([A-Z][A-Z_]+)\\)")
	for label in editor.find_children("*", "RichTextLabel", true, false):
		var rich := label as RichTextLabel
		if rich == null or code.is_ancestor_of(rich):
			continue
		for raw in rich.get_parsed_text().split("\n", false):
			var text := raw.strip_edges().trim_prefix("[Ignore]").strip_edges()
			var found := line_number.search(text)
			var colon := text.find(":")
			if text.is_empty() or found == null or colon < 0 or problems.size() >= 20:
				continue
			var line := int(found.get_string(1))
			var message := text.substr(colon + 1).strip_edges()
			# The status bar and the errors panel say the same thing in two ways.
			var key := "%d|%s" % [line, message.to_lower()]
			if message.is_empty() or seen.has(key):
				continue
			seen[key] = true
			var code_match := warning_code.search(text)
			var severity := "warning" if code_match or text.to_lower().contains("warning") else "error"
			if code_match:
				message = "%s (%s)" % [message, code_match.get_string(1)]
			problems.append({
				"line": line,
				"severity": severity,
				"message": message.substr(0, 300),
				"source": "Godot",
			})
	return problems


## The scene, its tree, the selected nodes and what's open, as plain text.
static func _details(main_screen: String, root: Node, script: Script) -> String:
	var lines: PackedStringArray = []
	var version: Dictionary = Engine.get_version_info()
	var project_name := str(ProjectSettings.get_setting("application/config/name", ""))
	lines.append("Godot %s · project \"%s\" · main screen: %s" % [version.get("string", "?"), project_name, main_screen])

	if root:
		var scene_path := root.scene_file_path if not root.scene_file_path.is_empty() else "(not saved yet)"
		lines.append("Open scene: %s" % scene_path)
		lines.append("Scene tree:")
		var counter := [0]
		_tree(root, root, 0, lines, counter)
		if counter[0] >= MAX_TREE_NODES:
			lines.append("  … (more nodes)")
	else:
		lines.append("No scene open.")

	var selected := EditorInterface.get_selection().get_selected_nodes()
	if not selected.is_empty():
		lines.append("Selected node%s:" % ("s" if selected.size() > 1 else ""))
		for i in mini(selected.size(), 3):
			var node: Node = selected[i]
			var path := str(root.get_path_to(node)) if root and (node == root or root.is_ancestor_of(node)) else node.name
			lines.append("- %s (%s)%s" % [path, node.get_class(), _script_note(node)])
			for prop in _changed_properties(node):
				lines.append("    " + prop)
		if selected.size() > 3:
			lines.append("- … and %d more" % (selected.size() - 3))

	var scripts := EditorInterface.get_script_editor().get_open_scripts() if EditorInterface.get_script_editor() else []
	if not scripts.is_empty():
		var names: PackedStringArray = []
		for s in scripts:
			if s and not s.resource_path.is_empty():
				names.append(s.resource_path)
		if not names.is_empty():
			lines.append("Open scripts: " + ", ".join(names))
	if script and not script.resource_path.is_empty():
		lines.append("Script in the script editor: " + script.resource_path)

	var scenes := EditorInterface.get_open_scenes()
	if scenes.size() > 1:
		lines.append("Other open scenes: " + ", ".join(scenes))
	return "\n".join(lines)


static func _tree(node: Node, root: Node, depth: int, lines: PackedStringArray, counter: Array) -> void:
	if counter[0] >= MAX_TREE_NODES:
		return
	counter[0] += 1
	var instanced := ""
	if node != root and not node.scene_file_path.is_empty():
		instanced = " instance=" + node.scene_file_path
	lines.append("%s%s (%s)%s%s" % ["  ".repeat(depth + 1), node.name, node.get_class(), _script_note(node), instanced])
	# An instanced scene's own children belong to its file: don't list them.
	if node != root and not node.scene_file_path.is_empty():
		return
	if depth + 1 >= MAX_TREE_DEPTH:
		if node.get_child_count() > 0:
			lines.append("%s…" % "  ".repeat(depth + 2))
		return
	for child in node.get_children():
		if child.owner == root:  # scene nodes only, never the editor's own helpers
			_tree(child, root, depth + 1, lines, counter)


static func _script_note(node: Node) -> String:
	var s: Script = node.get_script()
	return " script=" + s.resource_path if s and not s.resource_path.is_empty() else ""


## The properties the user changed from their default (and the script's exported ones).
static func _changed_properties(node: Node) -> PackedStringArray:
	var out: PackedStringArray = []
	var cls := node.get_class()
	var native := {}  # properties of the node's Godot class (the rest come from its script)
	for p in ClassDB.class_get_property_list(cls, false):
		native[p.get("name", "")] = true
	for prop in node.get_property_list():
		var usage: int = prop.get("usage", 0)
		if usage & PROPERTY_USAGE_EDITOR == 0 or usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var name: String = prop.get("name", "")
		if name.is_empty() or name == "script":
			continue
		var value: Variant = node.get(name)
		if native.has(name):
			var default: Variant = ClassDB.class_get_property_default_value(cls, name)
			if typeof(default) == typeof(value) and default == value:
				continue
		elif value == null:
			continue
		out.append("%s = %s" % [name, _value_text(value)])
		if out.size() >= MAX_PROPERTIES:
			out.append("…")
			break
	return out


static func _value_text(value: Variant) -> String:
	if value is Resource:
		var res: Resource = value
		return res.resource_path if not res.resource_path.is_empty() else "<%s>" % res.get_class()
	if value is Object:
		return "<%s>" % (value as Object).get_class()
	var text := var_to_str(value).replace("\n", " ")
	return text if text.length() <= MAX_VALUE else text.substr(0, MAX_VALUE) + "…"


## The whole editor window as a PNG in the temp folder (Lumo copies it into its own folder).
static func _snapshot() -> String:
	var base := EditorInterface.get_base_control()
	if base == null or DisplayServer.get_name() == "headless":
		return ""
	var texture := base.get_viewport().get_texture()
	if texture == null:
		return ""
	var image := texture.get_image()
	if image == null or image.is_empty():
		return ""
	if image.get_width() > MAX_SNAPSHOT_WIDTH:
		var ratio := float(MAX_SNAPSHOT_WIDTH) / image.get_width()
		image.resize(MAX_SNAPSHOT_WIDTH, int(image.get_height() * ratio), Image.INTERPOLATE_LANCZOS)
	var path := OS.get_temp_dir().path_join("lumo-godot-%d.png" % Time.get_unix_time_from_system())
	return path if image.save_png(path) == OK else ""
