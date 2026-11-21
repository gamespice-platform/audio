class_name GSAmbienceSet
extends RefCounted

## A sound set: moods read from a directory. `moods.json` is the document; a directory with
## none is read by folder (each subfolder a mood, see [method GSAmbienceMood.from_folder]).
## Format: `{"format": 1, "moods": {name: {"volume", "beds": [...], "oneshots": [...]}}}`.

const CHANNEL := "audio.ambience"
const FILE := "moods.json"

## Mood name -> [GSAmbienceMood].
var moods: Dictionary = {}

## Files a mood named and the disk lacked (silence, not an error).
var dropped: PackedStringArray = PackedStringArray()


## Reads [param dir]. The result's value is the set.
static func load_dir(dir: String) -> GSResult:
	var set := GSAmbienceSet.new()
	var file := dir.path_join(FILE)
	if FileAccess.file_exists(file):
		var json := JSON.new()
		var parsed: Variant = json.data if json.parse(FileAccess.get_file_as_string(file)) == OK else null
		if parsed == null:
			return GSResult.fail(GSError.CODE_PARSE, "%s is not JSON: %s" % [file, json.get_error_message()])
		if not (parsed is Dictionary) or not ((parsed as Dictionary).get("moods", {}) is Dictionary):
			return GSResult.fail(GSError.CODE_PARSE, "%s is not an ambience document" % file)
		var table: Dictionary = (parsed as Dictionary).get("moods", {})
		for id: String in table:
			if table[id] is Dictionary:
				set._add(GSAmbienceMood.from_dictionary(id, table[id], dir, set.dropped))
	elif DirAccess.dir_exists_absolute(dir) or DirAccess.open(dir) != null:
		if OS.has_feature("template"):
			GSLog.warn(CHANNEL, "no moods.json in an exported build; check the preset exports .json (all_resources does in 4.7)", {"dir": dir})
		for sub in DirAccess.get_directories_at(dir):
			set._add(GSAmbienceMood.from_folder(sub, dir.path_join(sub)))
	else:
		return GSResult.fail(GSError.CODE_IO, "no sound set at %s" % dir)
	if not set.dropped.is_empty():
		GSLog.warn(CHANNEL, "a sound set names files it lacks", {"dir": dir, "missing": set.dropped.size(), "first": set.dropped[0]})
	return GSResult.success(set)


func _add(m: GSAmbienceMood) -> void:
	if not m.is_empty():
		moods[m.name] = m


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for k: StringName in moods:
		out.append(String(k))
	out.sort()
	return out
