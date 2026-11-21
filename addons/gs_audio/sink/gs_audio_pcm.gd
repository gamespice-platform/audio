extends RefCounted

## Decodes a short compressed stream to PCM once on a worker thread: an Ogg voice start builds a decoder (about 1 ms on the game thread),
## PCM starts in microseconds. Without threads (web) [method pump] slices it per frame for [member slice_usec], capped at [constant WEB_BUDGET_BYTES].
## Its own script so the sink never names itself statically; one cache per process, shared by path through [method copy_for].

const CHUNK := 4096

## Decodes running at once: the worker pool is shared with whatever else the game threads.
const JOBS := 2

## Key (a stream's path) -> its decoded [AudioStreamWAV].
static var _copies: Dictionary = {}
## Every decoded copy, so a player knows to make up [constant HEADROOM_DB].
static var _is_copy: Dictionary = {}
## Key -> [task, out, booked bytes].
static var _jobs: Dictionary = {}
static var _skipped: Dictionary = {}
static var _bytes := 0

## Without threads: key -> [playback (null until started), chunks, frames wanted, rate, booked
## bytes, stream, frames done], decoded in insertion order by [method pump].
static var _slices: Dictionary = {}
## Whether [method pump] is connected to the frame.
static var _pumping := false

## Takes the sliced path even with threads, as a suite does to cover the web's path natively.
static var slice_always := false
## Without threads: game-thread time [method pump] may spend a frame, in microseconds.
static var slice_usec := 1500
## Without threads: decodes waiting at most; a further sound plays compressed until one is done.
const SLICE_QUEUE := 48
## Frames decoded per step of a slice: small enough that one step stays well under the slice.
const SLICE_CHUNK := 2048
## Without threads, the held copies never pass this, whatever a caller's budget.
const WEB_BUDGET_BYTES := 24 * 1024 * 1024

## Warm-up: game-thread microseconds a frame may spend loading streams and starting decodes (at least one item a
## frame). 0 is no limit: everything queued is handled the frame it is queued.
static var warm_usec := 1500
## Warm-up queue: [key or path, stream or null, resolver] rows, oldest first.
static var _warm: Array = []
static var _warm_connected := false
static var _warm_total := 0
static var _warm_kept := 0

## Stored at half scale and played [constant HEADROOM_DB] louder: a decoder overshoots full
## scale on a loud transient (1.27 measured on a stock step), and 16 bits would clip what the
## float mix carries through to the limiter.
const HEADROOM := 0.5
const HEADROOM_DB := 6.0206


## Appends an [AudioStreamWAV] holding [param stream] at [param rate] to [param out], or
## nothing when it cannot be decoded. Safe on a worker thread: it touches only its arguments.
static func decode(stream: AudioStream, rate: int, out: Array) -> void:
	var want := int(ceil(stream.get_length() * float(rate)))
	var playback := stream.instantiate_playback()
	if playback == null or want <= 0 or rate <= 0:
		return
	playback.start(0.0)
	var frames := PackedVector2Array()
	while frames.size() < want:
		var chunk := playback.mix_audio(1.0, mini(CHUNK, want - frames.size()))
		if chunk.is_empty():
			break
		frames.append_array(chunk)
	playback.stop()
	var count := frames.size()
	if count == 0:
		return

	# A mono source comes back as two equal channels; kept as one, it is half the memory.
	var stereo := false
	for i in range(count):
		if frames[i].x != frames[i].y:
			stereo = true
			break

	var data := PackedByteArray()
	if stereo:
		data.resize(count * 4)
		for i in range(count):
			var f := frames[i]
			data.encode_s16(i * 4, clampi(int(f.x * HEADROOM * 32767.0), -32768, 32767))
			data.encode_s16(i * 4 + 2, clampi(int(f.y * HEADROOM * 32767.0), -32768, 32767))
	else:
		data.resize(count * 2)
		for i in range(count):
			data.encode_s16(i * 2, clampi(int(frames[i].x * HEADROOM * 32767.0), -32768, 32767))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = stereo
	wav.data = data
	out.append(wav)


## The PCM copy of [param stream] (named by [param key], its path) once decoded, else [param stream]: the first play is compressed
## and starts the decode; a copy is half scale, so play it [constant HEADROOM_DB] louder. Never past [param max_seconds] or [param budget_bytes],
## and never for a loop (its resampled ends click; the caller's check). Without threads [method pump] decodes, capped at [constant WEB_BUDGET_BYTES].
static func copy_for(key: String, stream: AudioStream, max_seconds: float = 4.0, budget_bytes: int = 64 * 1024 * 1024) -> AudioStream:
	if _copies.has(key):
		return _copies[key] as AudioStream
	if _skipped.has(key) or key.is_empty() or _slices.has(key):
		return stream
	if _jobs.has(key):
		collect(false)
		return _copies.get(key, stream) as AudioStream
	if not (stream is AudioStreamOggVorbis or stream is AudioStreamMP3):
		_skipped[key] = true
		return stream
	var rate := int(AudioServer.get_mix_rate())
	var seconds := stream.get_length()
	# Booked as stereo until the decode says otherwise.
	var cost := int(seconds * float(rate)) * 4
	var sliced := slice_always or not threaded()
	if sliced:
		budget_bytes = mini(budget_bytes, WEB_BUDGET_BYTES)
	# Not remembered as skipped: another caller's limits may allow it.
	if seconds <= 0.0 or seconds > max_seconds or _bytes + cost > budget_bytes:
		return stream
	if sliced:
		_queue_slice(key, stream, rate, cost)
		return stream
	if _jobs.size() >= JOBS:
		collect(false)
		if _jobs.size() >= JOBS:
			return stream
	var out: Array = []
	var task := WorkerThreadPool.add_task(decode.bind(stream, rate, out), false, "gs-audio pcm")
	_jobs[key] = [task, out, cost]
	_bytes += cost
	return stream


## Without threads: books [param key] for [method pump]; the decoder is set up there, not here,
## so the play that asked pays nothing more than its own start.
static func _queue_slice(key: String, stream: AudioStream, rate: int, cost: int) -> void:
	if _slices.size() >= SLICE_QUEUE:
		return
	_slices[key] = [null, [], int(ceil(stream.get_length() * float(rate))), rate, cost, stream, 0]
	_bytes += cost
	if not _pumping:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			tree.process_frame.connect(pump)
			_pumping = true


## Without threads: decodes the queued sounds, oldest first, for at most [param usec] microseconds
## ([member slice_usec] when negative; at least one step). Runs once a frame on its own while any
## are queued; a suite calls it with a large [param usec] to finish them now.
static func pump(usec: int = -1) -> void:
	var until := Time.get_ticks_usec() + (slice_usec if usec < 0 else usec)
	while not _slices.is_empty():
		var key: String = _slices.keys()[0]
		var job: Array = _slices[key]
		var stream := job[5] as AudioStream
		var want := int(job[2])
		var chunks: Array = job[1]
		var done := int(job[6])
		if job[0] == null:
			var playback := stream.instantiate_playback()
			if playback == null:
				_drop_slice(key, true)
				continue
			playback.start(0.0)
			job[0] = playback
		elif done < want:
			var chunk := (job[0] as AudioStreamPlayback).mix_audio(1.0, mini(SLICE_CHUNK, want - done))
			if chunk.is_empty():
				job[2] = done
			else:
				chunks.append(chunk)
				job[6] = done + chunk.size()
		else:
			(job[0] as AudioStreamPlayback).stop()
			var frames := PackedVector2Array()
			for c: PackedVector2Array in chunks:
				frames.append_array(c)
			var wav := _wav_native(frames, int(job[3]))
			_drop_slice(key, wav == null)
			if wav != null:
				_bytes += wav.data.size()
				_copies[key] = wav
				_is_copy[wav] = true
		if Time.get_ticks_usec() >= until:
			break
	if _slices.is_empty():
		_stop_pump()


static func _drop_slice(key: String, skip: bool) -> void:
	var job: Array = _slices[key]
	_slices.erase(key)
	_bytes -= int(job[4])
	if skip:
		_skipped[key] = true


static func _stop_pump() -> void:
	if not _pumping:
		return
	_pumping = false
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(pump):
		tree.process_frame.disconnect(pump)


## [param frames] (a decoder's float pairs) as [method decode]'s half-scale 16-bit copy, built by
## native calls only: a per-sample loop in script is what makes the threaded decode too slow for
## the game thread. Mono when the two channels are equal everywhere, as in [method decode].
static func _wav_native(frames: PackedVector2Array, rate: int) -> AudioStreamWAV:
	var count := frames.size()
	if count == 0 or rate <= 0:
		return null
	# (x - y, 0) for every frame: exactly +0.0 in both lanes where the channels are equal.
	var diff := Transform2D(Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2.ZERO) * frames
	var zeros := PackedByteArray()
	zeros.resize(count * 8)
	var stereo := diff.to_byte_array() != zeros
	var body := (Transform2D(Vector2(HEADROOM, 0.0), Vector2(0.0, HEADROOM), Vector2.ZERO) * frames).to_byte_array()
	# A float WAV in memory; the engine's reader turns it into 16 bits (and one channel) natively.
	var head := PackedByteArray()
	head.resize(44)
	head.encode_u32(0, 0x46464952)  # "RIFF"
	head.encode_u32(4, 36 + body.size())
	head.encode_u32(8, 0x45564157)  # "WAVE"
	head.encode_u32(12, 0x20746d66)  # "fmt "
	head.encode_u32(16, 16)
	head.encode_u16(20, 3)  # IEEE float
	head.encode_u16(22, 2)
	head.encode_u32(24, rate)
	head.encode_u32(28, rate * 8)
	head.encode_u16(32, 8)
	head.encode_u16(34, 32)
	head.encode_u32(36, 0x61746164)  # "data"
	head.encode_u32(40, body.size())
	head.append_array(body)
	var wav := AudioStreamWAV.load_from_buffer(head, {
		"force/8_bit": false,
		"force/mono": not stereo,
		"force/max_rate": false,
		"force/max_rate_hz": 44100,
		"edit/trim": false,
		"edit/normalize": false,
		"edit/loop_mode": 0,
		"edit/loop_begin": 0,
		"edit/loop_end": -1,
		"compress/mode": 0,
	})
	if wav == null or wav.format != AudioStreamWAV.FORMAT_16_BITS:
		return null
	return wav


## Queues [param items] (an [AudioStream] with a resource path, or a path String that [param resolver]
## turns into one) so each is loaded and its PCM copy decoded before it is first played, a frame at a time
## within [member warm_usec]: the first shot, reload or footstep then finds both ready instead of paying the
## load and the decoder start on the frame it is heard. Nothing is capped; a decode the pool has no room for
## waits its turn. Returns the items queued (repeats and streams already copied do not count). Poll
## [method warm_pending] for the end.
static func warm(items: Array, resolver: Callable = Callable(), max_seconds: float = 4.0, budget_bytes: int = 64 * 1024 * 1024) -> int:
	var queued := 0
	for item: Variant in items:
		var key := ""
		var stream: AudioStream = null
		if item is AudioStream:
			stream = item as AudioStream
			key = stream.resource_path
		elif item is String or item is StringName:
			key = String(item)
		if key.is_empty() or _copies.has(key) or _skipped.has(key) or _warm_has(key):
			continue
		_warm.append([key, stream, resolver, max_seconds, budget_bytes])
		_warm_total += 1
		queued += 1
	if queued > 0 and not _warm_connected:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			tree.process_frame.connect(_warm_tick)
			_warm_connected = true
	return queued


## Items [method warm] still has to load or decode.
static func warm_pending() -> int:
	return _warm.size()


## Streams [method warm] has handled, and how many of them it holds a copy of: {"queued", "copied"}.
static func warm_stats() -> Dictionary:
	return {"queued": _warm_total, "copied": _warm_kept, "pending": _warm.size()}


static func _warm_has(key: String) -> bool:
	for row: Array in _warm:
		if row[0] == key:
			return true
	return false


static func _warm_tick() -> void:
	warm_step(warm_usec)


## One round of [method warm]: handles queued items for [param usec] microseconds (0: all; at least one), in order.
## Runs once a frame on its own; a suite calls it to finish now.
static func warm_step(usec: int) -> void:
	collect(false)
	var until := Time.get_ticks_usec() + usec
	var i := 0
	while i < _warm.size():
		var row: Array = _warm[i]
		var key: String = row[0]
		if _copies.has(key) or _skipped.has(key):
			_warm_finish(i, _copies.has(key))
			continue
		if _jobs.has(key) or _slices.has(key):
			i += 1  # decoding; collected or pumped elsewhere
			continue
		var stream := row[1] as AudioStream
		if stream == null:
			var resolver: Callable = row[2]
			stream = resolver.call(key) as AudioStream if resolver.is_valid() else null
			if stream == null:
				_warm_finish(i, false)
				continue
			row[1] = stream
		var sliced := slice_always or not threaded()
		if (sliced and _slices.size() >= SLICE_QUEUE) or (not sliced and _jobs.size() >= JOBS):
			i += 1  # no room yet: the next frame's turn
		else:
			var _s := copy_for(key, stream, float(row[3]), int(row[4]))
			if _jobs.has(key) or _slices.has(key):
				i += 1
			else:
				_warm_finish(i, _copies.has(key))  # taken at once, or refused (too long, over budget)
		if usec > 0 and Time.get_ticks_usec() >= until:
			break
	if _warm.is_empty() and _warm_connected:
		_warm_connected = false
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.process_frame.is_connected(_warm_tick):
			tree.process_frame.disconnect(_warm_tick)


static func _warm_finish(index: int, copied: bool) -> void:
	_warm.remove_at(index)
	if copied:
		_warm_kept += 1


## True for a copy [method copy_for] handed out, which plays [constant HEADROOM_DB] louder.
static func is_copy(stream: AudioStream) -> bool:
	return stream is AudioStreamWAV and _is_copy.has(stream)


## Takes in every finished decode; with [param wait], blocks for the ones still running.
static func collect(wait: bool) -> void:
	for key: String in _jobs.keys():
		var job: Array = _jobs[key]
		var task := int(job[0])
		if not wait and not WorkerThreadPool.is_task_completed(task):
			continue
		var _err := WorkerThreadPool.wait_for_task_completion(task)
		_jobs.erase(key)
		_bytes -= int(job[2])
		var out: Array = job[1]
		if out.is_empty():
			_skipped[key] = true
			continue
		var wav := out[0] as AudioStreamWAV
		_bytes += wav.data.size()
		_copies[key] = wav
		_is_copy[wav] = true


## Drops every copy (after waiting out the running decodes), so nothing static holds a stream at quit.
static func clear() -> void:
	collect(true)
	_slices.clear()
	_stop_pump()
	_copies.clear()
	_is_copy.clear()
	_skipped.clear()
	_bytes = 0
	_warm.clear()
	_warm_total = 0
	_warm_kept = 0
	if _warm_connected:
		_warm_connected = false
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.process_frame.is_connected(_warm_tick):
			tree.process_frame.disconnect(_warm_tick)


static func threaded() -> bool:
	return OS.get_processor_count() > 1 and (not OS.has_feature("web") or OS.has_feature("threads"))
