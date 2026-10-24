# TTS audio fixtures

All fixtures contain the same generated 440 Hz sine wave: 0.25 seconds,
24 kHz mono, peak amplitude 6000 in signed 16-bit PCM. No speech or private data.

`tone.pcm` is raw little-endian PCM; `tone.wav` wraps those exact samples.
Other files were encoded from that WAV with FFmpeg (a fixture creation tool,
not an application dependency): libmp3lame at 64 kbps, libopus at 32 kbps in
Ogg, FLAC, and AAC at 64 kbps in ADTS. Lossy encoders may add padding.

Python tests read these files directly. Native playback tests pass them through
the production TTS adapter using `.runtime/venv/bin/python`, then check
AVAudioPlayer preparation and AVAudioFile sample data, without audible playback.
