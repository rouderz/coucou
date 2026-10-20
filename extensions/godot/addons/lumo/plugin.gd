@tool
extends EditorPlugin
## Lumo for Godot: ask Lumo about what you're doing, with the script, the scene, the selected
## node and a snapshot of the editor attached. Talks to Lumo on this computer only.
##
##   • "Lumo" button in the editor toolbar, Ctrl+Alt+L (Cmd+Alt+L on macOS), the command
##     palette, and "Ask Lumo about this" when right-clicking code or nodes: Lumo opens its chat
##     with the context attached.
##   • While Lumo is open, the plugin keeps it told about the script / scene in front (no
##     snapshot), so Lumo's own shortcut and dropping your character on Godot use it too.
##     Editor Settings → Lumo → Share Context turns that off.

const LumoClient := preload("lumo_client.gd")
const LumoContext := preload("lumo_context.gd")
const LumoMenu := preload("lumo_menu.gd")

const SETTING_SHARE := "lumo/share_context"
const SETTING_SNAPSHOT := "lumo/attach_editor_snapshot"
const CONTEXT_DEBOUNCE := 0.6

var _client: LumoClient
var _button: Button
var _menu_code: LumoMenu
var _menu_tree: LumoMenu
var _main_screen := "2D"
var _debounce: Timer
var _code_edit: CodeEdit
var _shortcut: Shortcut
var _last_context_json := ""


func _enter_tree() -> void:
	_client = LumoClient.new()
	_client.answered.connect(_on_answered)

	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_SHARE):
		settings.set_setting(SETTING_SHARE, true)
	settings.set_initial_value(SETTING_SHARE, true, false)
	if not settings.has_setting(SETTING_SNAPSHOT):
		settings.set_setting(SETTING_SNAPSHOT, true)
	settings.set_initial_value(SETTING_SNAPSHOT, true, false)

	_button = Button.new()
	_button.text = "Lumo"
	var icon := _icon()
	_button.icon = icon
	_button.flat = true
	_button.tooltip_text = "Ask Lumo about what you're doing (Ctrl+Alt+L)"
	_button.pressed.connect(ask)
	add_control_to_container(CONTAINER_TOOLBAR, _button)

	_menu_code = LumoMenu.new()
	_menu_code.on_ask = ask
	_menu_code.icon = icon
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE, _menu_code)
	_menu_tree = LumoMenu.new()
	_menu_tree.on_ask = ask
	_menu_tree.icon = icon
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _menu_tree)

	var palette := EditorInterface.get_command_palette()
	if palette:
		palette.add_command("Ask Lumo About This", "lumo/ask", ask, "Ctrl+Alt+L")

	var key := InputEventKey.new()
	key.keycode = KEY_L
	key.ctrl_pressed = true
	key.alt_pressed = true
	key.command_or_control_autoremap = true
	_shortcut = Shortcut.new()
	_shortcut.events = [key]

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = CONTEXT_DEBOUNCE
	_debounce.timeout.connect(_share_context)
	add_child(_debounce)

	main_screen_changed.connect(_on_main_screen_changed)
	scene_changed.connect(func(_root: Node) -> void: _context_changed())
	EditorInterface.get_selection().selection_changed.connect(_context_changed)
	var script_editor := EditorInterface.get_script_editor()
	if script_editor:
		script_editor.editor_script_changed.connect(func(_s: Script) -> void: _watch_code_edit())
	_watch_code_edit()
	set_process(false)


func _exit_tree() -> void:
	if _client:
		_client.close()
	if _button:
		remove_control_from_container(CONTAINER_TOOLBAR, _button)
		_button.queue_free()
	if _menu_code:
		remove_context_menu_plugin(_menu_code)
	if _menu_tree:
		remove_context_menu_plugin(_menu_tree)
	var palette := EditorInterface.get_command_palette()
	if palette:
		palette.remove_command("lumo/ask")
	var selection := EditorInterface.get_selection()
	if selection.selection_changed.is_connected(_context_changed):
		selection.selection_changed.disconnect(_context_changed)
	_unwatch_code_edit()


func _shortcut_input(event: InputEvent) -> void:
	if _shortcut and event.is_pressed() and not event.is_echo() and _shortcut.matches_event(event):
		get_viewport().set_input_as_handled()
		ask()


func _process(_delta: float) -> void:
	_client.poll()
	if not _client.is_busy():
		set_process(false)


## Opens Lumo's chat with what's in front of the user.
func ask() -> void:
	var snapshot := bool(EditorInterface.get_editor_settings().get_setting(SETTING_SNAPSHOT))
	var payload := LumoContext.gather(_main_screen, snapshot)
	if not _client.send("EditorAsk", payload):
		_toast("Lumo isn't running. Open Lumo and try again.", EditorToaster.SEVERITY_WARNING)
		return
	set_process(true)


func _on_answered(event: String, ok: bool, error: String) -> void:
	if event != "EditorAsk":
		return
	if not ok:
		_toast("Lumo: " + (error if not error.is_empty() else "it didn't take the question."), EditorToaster.SEVERITY_WARNING)


func _on_main_screen_changed(screen: String) -> void:
	_main_screen = screen
	_context_changed()


func _context_changed() -> void:
	if not bool(EditorInterface.get_editor_settings().get_setting(SETTING_SHARE)):
		return
	if not LumoClient.lumo_available():
		return
	_debounce.start()


func _share_context() -> void:
	var payload := LumoContext.gather(_main_screen, false)
	# The details change with every selection; only send when something did.
	var text := JSON.stringify(payload)
	if text == _last_context_json:
		return
	_last_context_json = text
	if _client.send("EditorContext", payload):
		set_process(true)


func _watch_code_edit() -> void:
	_unwatch_code_edit()
	var editor := EditorInterface.get_script_editor().get_current_editor() if EditorInterface.get_script_editor() else null
	_code_edit = editor.get_base_editor() as CodeEdit if editor else null
	if _code_edit:
		_code_edit.caret_changed.connect(_context_changed)
	_context_changed()


func _unwatch_code_edit() -> void:
	if is_instance_valid(_code_edit) and _code_edit.caret_changed.is_connected(_context_changed):
		_code_edit.caret_changed.disconnect(_context_changed)
	_code_edit = null


## The icon next to the plugin (loaded, not preloaded: right after copying the addon it may not
## be imported yet, and the plugin must load anyway).
func _icon() -> Texture2D:
	var path := (get_script() as Script).resource_path.get_base_dir().path_join("lumo_icon.svg")
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


func _toast(message: String, severity: int) -> void:
	var toaster := EditorInterface.get_editor_toaster()
	if toaster:
		toaster.push_toast(message, severity)
	else:
		push_warning(message)
