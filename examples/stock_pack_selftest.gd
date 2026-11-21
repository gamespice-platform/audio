extends Node

## The ambience beds and mood set left out of the client shell's pck still resolve once a pack carrying them is mounted and listed in
## GSAudioStock.fallback_roots. The pack is built here (PCKPacker, tiny streams); no CDN, no GameSpice Cloud.

const POOL := "res://dot_cloud/synth/1/stock"
const SHELL := "res://shell_without_stock"

var _passed := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL ", what)


func _run() -> void:
	print("dot-audio stock pack")
	var pck := _build_pack()
	_check(not pck.is_empty(), "synthetic pack built")

	GSAudioStock.directory_override = SHELL
	_check(GSAudioStock.fallback_roots.is_empty(), "no fallback root by default")
	var before := GSAudioStock.ambience_defs()
	_check(before[0].path == SHELL + "/ambience/amb_wind.ogg", "before the mount: a bed keeps its own (missing) path")
	_check(not GSAmbienceSet.load_dir(GSAudioStock.moods_directory()).ok, "before the mount: the shell has no mood set")

	_check(ProjectSettings.load_resource_pack(pck), "synthetic pack mounts")
	_check(GSAudioStock.ambience_defs()[0].path.begins_with(SHELL), "mounted but not listed: still the shell's path")

	GSAudioStock.fallback_roots = PackedStringArray([POOL])
	var defs := GSAudioStock.ambience_defs()
	var wind: GSAudioDef = defs[0]
	_check(wind.path == POOL + "/ambience/amb_wind.ogg", "listed: the bed the pack carries resolves into it")
	_check(ResourceLoader.exists(wind.path) and load(wind.path) is AudioStream, "and loads as a stream")
	_check(defs[1].path.begins_with(SHELL), "a bed the pack lacks keeps the shell's path")
	_check(GSAudioStock.moods_directory() == POOL + "/moods", "the mood set resolves into the pack")
	var set := GSAmbienceSet.load_dir(GSAudioStock.moods_directory())
	_check(set.ok, "the pack's mood set loads")
	if set.ok:
		var m: GSAmbienceMood = (set.value as GSAmbienceSet).moods.get(&"synth")
		_check(m != null and m.beds.size() == 1 and String(m.beds[0]["file"]).begins_with(POOL), "its bed file is the pack's")

	_shots_and_weapons()

	GSAudioStock.directory_override = ""
	var real := GSAudioStock.directory().path_join("ambience/amb_wind.ogg")
	_check(GSAudioStock.resolve("ambience/amb_wind.ogg") == real, "a build that carries the file keeps its own path")
	GSAudioStock.fallback_roots = PackedStringArray()
	print("RESULT %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


## Shot and weapon stock: overlay-only (the pack carries one file of each), in-tree (no override), missing (logged once).
func _shots_and_weapons() -> void:
	GSAudioStock.directory_override = SHELL
	GSAudioStock.fallback_roots = PackedStringArray([POOL])
	var light := GSAudioShotStock.shot(&"light")
	_check(light.attack[0] == POOL + "/shots/light/attack_0.ogg", "overlay-only: a shot file the pack carries resolves into it")
	_check(light.attack[1] == SHELL + "/shots/light/attack_1.ogg", "a shot file the pack lacks keeps the shell path")
	_check(ResourceLoader.exists(light.attack[0]), "the overlay shot file loads")
	var dry: GSAudioDef = null
	for d in GSAudioWeaponStock.defs():
		if d.id == &"weapon_dry":
			dry = d
	_check(dry != null and dry.variants[0] == POOL + "/weapons/dry_0.ogg", "overlay-only: a weapon file resolves into the pack")
	_check(dry != null and dry.path == dry.variants[0] and dry.variants[1].begins_with(SHELL), "its other variants keep the shell path")

	GSAudioStock.fallback_roots = PackedStringArray()
	GSAudioStock._warned.clear()
	var gone := GSAudioShotStock.shot(&"rifle")
	_check(gone.attack[0] == SHELL + "/shots/rifle/attack_0.ogg" and not ResourceLoader.exists(gone.attack[0]), "missing: the path fails at its own place")
	_check(GSAudioStock._warned.has("shots/rifle/attack_0.ogg"), "missing: a shot file is logged as missing")
	GSAudioWeaponStock.defs()
	_check(GSAudioStock._warned.has("weapons/dry_0.ogg"), "missing: a weapon file is logged as missing")

	GSAudioStock.directory_override = ""
	GSAudioStock._warned.clear()
	var rifle := GSAudioShotStock.shot(&"rifle")
	_check(rifle.attack[0] == GSAudioShotStock.directory().path_join("rifle/attack_0.ogg"), "in-tree: a shot keeps its own path")
	_check(GSAudioWeaponStock.defs()[0].variants[0].begins_with(GSAudioWeaponStock.directory()), "in-tree: a weapon keeps its own path")
	_check(GSAudioStock._warned.is_empty(), "in-tree: nothing is logged missing")
	GSAudioStock.fallback_roots = PackedStringArray([POOL])
	_check(GSAudioShotStock.shot(&"light").attack[0] == GSAudioShotStock.directory().path_join("light/attack_0.ogg"), "in-tree wins over a fallback root")
	GSAudioStock.fallback_roots = PackedStringArray()
	GSAudioStock.directory_override = SHELL


func _build_pack() -> String:
	var stage := ProjectSettings.globalize_path("user://stock_stage")
	DirAccess.make_dir_recursive_absolute(stage)
	var out := ProjectSettings.globalize_path("user://stock_synth.pck")
	var packer := PCKPacker.new()
	if packer.pck_start(out) != OK:
		return ""
	var wav := AudioStreamWAV.new()
	wav.data = PackedByteArray([0, 0, 0, 0])
	var res := stage + "/s.res"
	ResourceSaver.save(wav, res)
	for rel: String in ["ambience/amb_wind.ogg", "moods/synth/bed.ogg", "shots/light/attack_0.ogg", "weapons/dry_0.ogg"]:
		var imp := stage + "/" + rel.replace("/", "_") + ".import"
		var fa := FileAccess.open(imp, FileAccess.WRITE)
		fa.store_string('[remap]\n\nimporter="keep"\npath="%s/%s.res"\n' % [POOL, rel])
		fa.close()
		packer.add_file("%s/%s.import" % [POOL, rel], imp)
		packer.add_file("%s/%s.res" % [POOL, rel], res)
	var doc := stage + "/moods.json"
	var jf := FileAccess.open(doc, FileAccess.WRITE)
	jf.store_string('{"format": 1, "moods": {"synth": {"beds": [{"file": "synth/bed.ogg", "volume": 1.0}]}}}')
	jf.close()
	packer.add_file(POOL + "/moods/moods.json", doc)
	if packer.flush() != OK:
		return ""
	return out
