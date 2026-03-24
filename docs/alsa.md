# ALSA Notes

Issues discovered while implementing realtime voice support with nim-alsa.

## Blocking Mode Enum Was Wrong

The nim-alsa `openModes` enum had incorrect values:

```
# WRONG (original)
BLOCKING_MODE = 0x00000001   # This is actually SND_PCM_NONBLOCK!
NON_BLOCKING_MODE = 0x00000002  # This is actually SND_PCM_ASYNC!

# CORRECT (fixed)
BLOCKING_MODE = 0x00000000     # 0 = blocking in ALSA C API
NON_BLOCKING_MODE = 0x00000001 # SND_PCM_NONBLOCK
ASYNC_MODE = 0x00000002        # SND_PCM_ASYNC
```

**Symptom**: `snd_pcm_readi_nim` returned only 64 frames per call instead of the
requested 4800 (200ms at 24kHz). The device was silently opening in non-blocking
mode, causing immediate returns with whatever tiny amount of data was available.

**Fix**: Changed `BLOCKING_MODE` to `0x00000000` in `nim-alsa/src/alsa.nim`.

## Missing Procs

The following ALSA functions were missing from nim-alsa and needed to be added
for playback and interruption support:

- `snd_pcm_writei_nim` - write interleaved audio to playback device
- `snd_pcm_close_nim` - close a PCM device
- `snd_pcm_prepare_nim` - prepare/reset a PCM device after error or drop
- `snd_pcm_drop_nim` - immediately stop playback, discarding buffered frames
- `snd_pcm_name_nim` - get the ALSA device name string

## Echo and Interruption

When using speakers (not headphones), the microphone picks up the assistant's
audio output. This confuses the server VAD (voice activity detection) because it
hears continuous "speech" from the speakers, preventing it from detecting the
user's actual interruption.

**Workaround**: Use headphones to avoid echo feedback. Proper fix would require
echo cancellation (e.g. PipeWire/PulseAudio echo-cancel module or a DSP
pipeline), which is outside the scope of this library.

## ALSA Device Names

`snd_pcm_name_nim` returns internal ALSA plugin names like `"default"` rather
than human-readable device descriptions. To get proper names (e.g. "BenQ EX3210U
Digital Stereo"), query PulseAudio/PipeWire via `pactl`:

```bash
pactl get-default-source  # default input device name
pactl get-default-sink    # default output device name
pactl list sources        # list all inputs with descriptions
pactl list sinks          # list all outputs with descriptions
```
