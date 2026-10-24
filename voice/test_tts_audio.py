import io
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import wave

from configuration import load_config
from providers import Cancelled, ProviderError, _speech_audio


FIXTURES = Path(__file__).resolve().parent.parent / 'tests/fixtures/tts'


class AudioFixture:
    def prepare(self, name, mime, body=None, cancelled=lambda: False, limit=16_000_000):
        settings = load_config()['tts']
        settings['response_format'] = name
        raw = (FIXTURES / f'tone.{name}').read_bytes() if body is None else body
        return _speech_audio(raw, mime, settings, cancelled, limit)


class SpeechAudioTests(AudioFixture, unittest.TestCase):
    def test_native_containers_are_preserved(self):
        for name, mime in (('mp3', 'audio/mpeg'), ('wav', 'audio/x-wav'),
                           ('flac', 'audio/flac'), ('aac', 'audio/aac')):
            with self.subTest(name=name):
                raw = (FIXTURES / f'tone.{name}').read_bytes()
                self.assertEqual(self.prepare(name, mime), raw)
                self.assertEqual(self.prepare(name, 'application/octet-stream'), raw)

    def test_mismatched_mime_container_and_disguised_errors_are_rejected(self):
        for name, mime, raw in (('mp3', 'audio/wav', (FIXTURES / 'tone.mp3').read_bytes()),
                                ('aac', 'audio/aac', (FIXTURES / 'tone.mp3').read_bytes()),
                                ('opus', 'audio/ogg', b'OggS-broken'),
                                ('opus', 'audio/ogg', b'OggS\0OpusHead-corrupt'),
                                ('flac', 'audio/flac', b'garbage'),
                                ('pcm', 'application/octet-stream', b'{"error":"private failure"}'),
                                ('pcm', 'audio/pcm', b'<html>failure</html>'),
                                ('pcm', 'audio/pcm', (FIXTURES / 'tone.wav').read_bytes()),
                                ('wav', 'audio/wav', b'RIFF-broken')):
            with self.subTest(name=name, mime=mime):
                with self.assertRaises(ProviderError) as error:
                    self.prepare(name, mime, raw)
                self.assertNotIn('private', str(error.exception))

    def test_raw_pcm_preserves_samples_and_duration(self):
        result = self.prepare('pcm', 'audio/pcm;rate=24000;channels=1')
        with wave.open(io.BytesIO(result)) as audio:
            self.assertEqual(audio.getnframes() / audio.getframerate(), .25)
            raw = audio.readframes(audio.getnframes())
            self.assertEqual(raw, (FIXTURES / 'tone.pcm').read_bytes())
            self.assertGreater(max(abs(s[0]) for s in struct.iter_unpack('<h', raw)), 1000)

    def test_empty_and_oversized_audio_is_rejected_including_wav_header(self):
        for name, body, limit in (('pcm', b'', 100), ('pcm', b'\x01\x02' * 30, 100),
                                  ('mp3', (FIXTURES / 'tone.mp3').read_bytes(), 100)):
            with self.subTest(name=name, limit=limit), self.assertRaises(ProviderError):
                self.prepare(name, 'application/octet-stream', body, limit=limit)

    def test_cancellation_before_conversion_never_returns_audio(self):
        with self.assertRaises(Cancelled):
            self.prepare('pcm', 'audio/pcm', cancelled=lambda: True)

    def test_missing_opus_decoder_is_safe_error(self):
        with patch.dict('sys.modules', {'soundfile': None}), self.assertRaises(ProviderError) as error:
            self.prepare('opus', 'audio/ogg')
        self.assertEqual(error.exception.code, 'audio_decoder_unavailable')


try:
    import soundfile
except ImportError:
    soundfile = None


@unittest.skipIf(soundfile is None, 'Run with .runtime/venv/bin/python for real Opus decoding')
class OpusAudioTests(AudioFixture, unittest.TestCase):
    def test_opus_becomes_wav_with_nonzero_signal_and_correct_duration(self):
        result = self.prepare('opus', 'audio/ogg')
        with wave.open(io.BytesIO(result)) as audio:
            self.assertEqual(audio.getnchannels(), 1)
            self.assertEqual(audio.getsampwidth(), 2)
            self.assertAlmostEqual(audio.getnframes() / audio.getframerate(), .25, places=3)
            self.assertGreater(max(abs(s[0]) for s in struct.iter_unpack('<h', audio.readframes(audio.getnframes()))), 1000)

    def test_opus_decode_expansion_is_bounded(self):
        with self.assertRaises(ProviderError) as error:
            self.prepare('opus', 'audio/ogg', limit=5000)
        self.assertEqual(error.exception.code, 'response_size')

    def test_corrupt_opus_is_safe_error(self):
        with self.assertRaises(ProviderError) as error:
            self.prepare('opus', 'audio/ogg', body=b'OggS\0OpusHead-corrupt')
        self.assertEqual(error.exception.code, 'invalid_audio')

    def test_cancellation_during_decode_never_returns_audio(self):
        checks = []
        def cancelled():
            checks.append(True)
            return len(checks) >= 3
        with self.assertRaises(Cancelled):
            self.prepare('opus', 'audio/ogg', cancelled=cancelled)
