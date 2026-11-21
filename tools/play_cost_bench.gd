extends Node

## What one play costs the game thread through the engine sink, built by hand since headless would pick the null sink and the cost
## (resolve the stream, take and configure a player) is in the real one. Prints microseconds per call; compare two builds on one box.

const ROUNDS := 200
const VOICES := 32
const FILE := "res://addons/gs_audio/stock/weapons/bash_0.ogg"
const MISSING := "res://sounds/not_shipped.ogg"


func _ready() -> void:
	var manager := GSAudioManager.new()
	manager.register_as_service = false
	manager.apply_mixer_to_buses = false
	manager.limit_master = false
	manager.voices = VOICES
	manager.catalogue = _catalogue()
	var sink := GSAudioSinkGodot.new(manager, VOICES)
	sink.bank = {MISSING: GSAudioSynth.bake(180.0, 60.0, 0.2)}
	manager.sink = sink
	add_child(manager)
	var res := manager.setup()
	if not res.ok:
		print("BENCH FAILED: ", res.error)
		get_tree().quit(1)
		return

	# Once round the pool first, so creating the players is not in any figure.
	_round(manager, &"file", [])
	_round(manager, &"banked", [])

	for id: StringName in [&"file", &"banked", &"far"]:
		var spent: Array[int] = [0, 0]
		for i in range(ROUNDS):
			_round(manager, id, spent)
		print("play_cost %-7s %7.1f us/play  (%d plays, %d heard)" % [id, float(spent[0]) / float(ROUNDS * VOICES), ROUNDS * VOICES, spent[1]])

	var t := Time.get_ticks_usec()
	for i in range(ROUNDS * VOICES):
		manager._process(0.016)
	print("play_cost idle    %7.1f us/frame (reap with nothing playing)" % (float(Time.get_ticks_usec() - t) / float(ROUNDS * VOICES)))

	for i in range(VOICES):
		var _h := manager.play_at(&"file", Vector3(1, 0, 0))
	t = Time.get_ticks_usec()
	for i in range(ROUNDS * VOICES):
		manager._process(0.016)
	print("play_cost full    %7.1f us/frame (reap with %d playing)" % [float(Time.get_ticks_usec() - t) / float(ROUNDS * VOICES), int(manager.sink.usage()["playing"])])

	manager.stop_all()
	manager.queue_free()
	await get_tree().process_frame
	GSAudioSinkGodot.clear_streams()
	get_tree().quit(0)


## Fills the pool with [param id] and empties it again; only the plays are timed.
func _round(manager: GSAudioManager, id: StringName, spent: Array) -> void:
	var heard := 0
	var t := Time.get_ticks_usec()
	for i in range(VOICES):
		if manager.play_at(id, Vector3(float(i), 0.0, 0.0)) != 0:
			heard += 1
	var took := Time.get_ticks_usec() - t
	manager.stop_all()
	if spent.size() == 2:
		spent[0] += took
		spent[1] += heard


func _catalogue() -> GSAudioCatalogue:
	var c := GSAudioCatalogue.new()
	c.add(_def(&"file", FILE, 0.0))
	c.add(_def(&"banked", MISSING, 0.0))
	# Past its own range: what a sound nobody can hear costs.
	c.add(_def(&"far", FILE, 0.5))
	return c


func _def(id: StringName, path: String, reach: float) -> GSAudioDef:
	var d := GSAudioDef.new()
	d.id = id
	d.path = path
	d.kind = GSAudioDef.Kind.POSITIONAL_3D
	d.max_distance = reach
	d.max_concurrent = 0
	if reach > 0.0:
		d.unit_size = reach * 0.5
	return d
