extends "selftest_shots.gd"

## The synth sections of [code]audio_selftest.gd[/code]: generated sounds, the bank, the Godot sink and looping.


func _synth_catalogue() -> GSAudioCatalogue:
	var c := GSAudioCatalogue.new()

	# Two variants, because the bank promises to keep them apart and a catalogue whose
	# defs all have one path cannot show that it does.
	var rifle := GSAudioDef.new()
	rifle.id = &"synth_rifle"
	rifle.path = "res://fixtures/rifle_a.ogg"
	rifle.variants = PackedStringArray(["res://fixtures/rifle_b.ogg"])
	c.add(rifle)

	var step := GSAudioDef.new()
	step.id = &"synth_step"
	step.path = "res://fixtures/step.ogg"
	c.add(step)

	return c


func _test_synth() -> void:
	_section("A synthesised stand-in, and the order it loses to a real file in")

	var shot := GSAudioSynth.voice(GSAudioSynth.Voice.SHOT)
	_check(shot != null and not shot.data.is_empty(), "a voice bakes to bytes")
	_check(
		(
			shot.format == AudioStreamWAV.FORMAT_16_BITS
			and not shot.stereo
			and shot.mix_rate == GSAudioSynth.RATE
		),
		"16-bit mono at the documented rate"
	)

	var frames := shot.data.size() / 2
	var seconds := float(frames) / float(GSAudioSynth.RATE)
	var wanted: float = GSAudioSynth.RECIPES[GSAudioSynth.Voice.SHOT][2]
	_check(absf(seconds - wanted) < 0.01, "and is as long as its recipe says")

	_check(
		GSAudioSynth.voice(GSAudioSynth.Voice.SHOT).data == shot.data,
		"the same voice bakes byte-identical twice, so two clients hear one shot"
	)

	var every := true
	for v in GSAudioSynth.RECIPES.keys():
		var one := GSAudioSynth.voice(v)
		if one == null or one.data.size() < 2:
			every = false
	_check(every, "every voice in the table bakes")

	# The envelope has to reach zero by the last frame. A buffer that stops mid-cycle is a
	# click on the end of every sound, which is the difference between placeholder audio
	# that is rough and placeholder audio nobody will leave switched on.
	var lo := shot.data[shot.data.size() - 2]
	var hi := shot.data[shot.data.size() - 1]
	var last := (hi << 8) | lo
	if last >= 32768:
		last -= 65536
	_check(absi(last) < 400, "and decays to silence rather than stopping mid-cycle")

	_check(
		(
			GSAudioSynth.bake(700.0, 90.0, 0.1, 0.5, 0.8, 0.004, 1).data
			!= GSAudioSynth.bake(700.0, 90.0, 0.1, 0.5, 0.8, 0.004, 2).data
		),
		"a different salt is a different noise"
	)

	var long_one := GSAudioSynth.bake(400.0, 200.0, 60.0)
	_check(
		float(long_one.data.size() / 2) / float(GSAudioSynth.RATE) <= 4.01,
		"an absurd length is clamped rather than allocating a minute of placeholder"
	)

	_test_synth_bank()


func _test_synth_bank() -> void:
	var cat := _synth_catalogue()
	var bank := GSAudioSynth.bank(
		cat,
		{
			&"synth_rifle": GSAudioSynth.Voice.SHOT,
			&"synth_step": GSAudioSynth.Voice.STEP,
			&"not_in_the_catalogue": GSAudioSynth.Voice.CLICK,
		}
	)

	_check(bank.has(&"synth_rifle"), "the bank answers by id")
	_check(bank.has("res://fixtures/rifle_a.ogg"), "and by the path the def names")
	_check(
		(
			bank.has("res://fixtures/rifle_b.ogg")
			and (bank["res://fixtures/rifle_b.ogg"] as AudioStreamWAV).data
				!= (bank["res://fixtures/rifle_a.ogg"] as AudioStreamWAV).data
		),
		"and a second variant is a different noise, so a rifle is not a metronome"
	)
	_check(not bank.has(&"not_in_the_catalogue"), "an id the catalogue does not have is skipped")
	_check(bank.has(&"synth_step"), "and the rest of the bank is still built")

	_test_synth_sink(bank)


func _test_synth_sink(bank: Dictionary) -> void:
	var host := Node.new()
	add_child(host)

	var sink := GSAudioSinkGodot.new(host, 8)

	var missing := {
		"id": "synth_rifle",
		"path": "res://fixtures/rifle_a.ogg",
		"kind": GSAudioDef.Kind.FLAT,
		"priority": 50,
	}
	_check(sink.play(missing) == 0, "with neither a file nor a bank, nothing plays")
	_check(sink.sink_name() == "godot", "and the sink says it has no bank")

	sink.bank = bank
	_check(sink.play(missing) != 0, "with a bank, the same request plays")
	_check(sink.sink_name().begins_with("godot+bank"), "and says so, for a bug report")

	var by_id := {"id": "synth_step", "path": "", "kind": GSAudioDef.Kind.FLAT, "priority": 50}
	_check(sink.play(by_id) != 0, "a def with no path at all resolves by id")

	# A real file has to win, or the bank is a placeholder somebody has to remember to
	# remove. user:// rather than res://, because a suite cannot write into its own build.
	var real := GSAudioSynth.bake(300.0, 300.0, 0.05, 0.2, 0.0)
	var probe_path := "user://dot_audio_probe.tres"
	var saved := ResourceSaver.save(real, probe_path) == OK
	sink.bank[probe_path] = GSAudioSynth.voice(GSAudioSynth.Voice.BOOM)

	var over := {"id": "probe", "path": probe_path, "kind": GSAudioDef.Kind.FLAT, "priority": 50}
	var handle := sink.play(over)
	var played: AudioStream = null
	for child in host.get_children():
		if int(child.get_meta(&"dot_audio_handle", 0)) == handle:
			played = child.get("stream") as AudioStream

	_check(saved and handle != 0, "a def whose path really exists plays")
	_check(
		played is AudioStreamWAV and (played as AudioStreamWAV).data == real.data,
		"and it is the FILE that plays, not the stand-in sitting at the same path"
	)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(probe_path))

	_test_synth_loop(host, sink, bank)


func _test_synth_loop(host: Node, sink: GSAudioSinkGodot, bank: Dictionary) -> void:
	# Assert on the stream the player was handed; the dummy driver's clock is not one to wait on.
	var stream_of := func(h: int) -> AudioStream:
		for child in host.get_children():
			if int(child.get_meta(&"dot_audio_handle", 0)) == h:
				return child.get("stream") as AudioStream
		return null

	var hum := {"id": "synth_step", "path": "", "kind": GSAudioDef.Kind.FLAT, "priority": 50, "looping": true}
	var hum_handle := sink.play(hum)
	var hum_stream := stream_of.call(hum_handle) as AudioStreamWAV
	var source := bank[&"synth_step"] as AudioStreamWAV
	_check(
		hum_stream != null and hum_stream.loop_mode == AudioStreamWAV.LOOP_FORWARD
		and hum_stream.loop_begin == 0 and hum_stream.loop_end == source.data.size() / 2,
		"a looping request plays a stream that loops, over every frame it has"
	)
	_check(
		source.loop_mode == AudioStreamWAV.LOOP_DISABLED,
		"and the bank's own stream is untouched, so the next one-shot of it does not loop"
	)
	var once := sink.play({"id": "synth_step", "path": "", "kind": GSAudioDef.Kind.FLAT, "priority": 50})
	_check(
		stream_of.call(once) == source,
		"a one-shot of the same sound still plays the one-shot"
	)
	_check(
		stream_of.call(sink.play(hum)) == hum_stream,
		"and a second loop of it reuses the one copy rather than duplicating per play"
	)

	# A stream type that cannot be told to loop goes round by restarting on `finished`.
	sink.bank[&"generated"] = AudioStreamGenerator.new()
	var gen := {"id": "generated", "path": "", "kind": GSAudioDef.Kind.FLAT, "priority": 50, "looping": true}
	var gen_handle := sink.play(gen)
	var gen_player: Node = null
	for child in host.get_children():
		if int(child.get_meta(&"dot_audio_handle", 0)) == gen_handle:
			gen_player = child
	if gen_player != null:
		gen_player.emit_signal("finished")
	_check(
		gen_handle != 0 and sink.is_playing(gen_handle),
		"and a stream that cannot loop natively restarts under the same handle when it ends"
	)
	sink.stop(gen_handle)
	_check(not sink.is_playing(gen_handle), "until it is stopped")

	# Playing players hold their playbacks until stopped; freeing the host alone leaves them at exit.
	sink.stop_all()
	host.queue_free()
