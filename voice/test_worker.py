import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from configuration import load_config
from providers import Cancelled, ProviderError, _speech_audio
import worker as module


RAW = json.dumps({'heard': 'привет', 'action': 'chat', 'book_id': None, 'reply': 'Привет!', 'page': 0})


class FakeWorker(module.VoiceWorker):
    def __init__(self):
        self._initialize(load_config())
        self.local_calls = 0

    def respond(self, text, audio_path, context, max_tokens=768):
        self.local_calls += 1
        yield SimpleNamespace(text=RAW)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.voice = FakeWorker()
        self.events = []
        self.patcher = patch.object(module, 'emit', lambda kind, **fields: self.events.append({'type': kind, **fields}))
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def test_online_decision_uses_same_validation_and_does_not_execute_an_action(self):
        self.voice.settings['llm']['mode'] = 'online'
        self.voice.remote = SimpleNamespace(decide=lambda *args: RAW)
        result = self.voice.decide('привет', None, {}, self.voice.sequence)
        self.assertEqual(result['reply'], 'Привет!')
        self.assertEqual(self.voice.local_calls, 0)

    def test_invalid_online_action_falls_back_to_local_decision(self):
        self.voice.settings['llm']['mode'] = 'online'
        self.voice.remote = SimpleNamespace(decide=lambda *args: '{"action":"shell","reply":"ok"}')
        result = self.voice.decide('привет', None, {}, self.voice.sequence)
        self.assertEqual(result['action'], 'chat')
        self.assertEqual(self.voice.local_calls, 1)
        self.assertTrue(self.events[-1]['fallback'])

    def test_end_command_clears_chat_before_any_provider_call(self):
        self.voice.history = [{'role': 'user', 'content': 'old chat'}]
        self.voice.active = True
        self.assertIsNone(self.voice.decide('Джарвис, закончили!', None, {}, self.voice.sequence))
        self.assertEqual(self.voice.local_calls, 0)
        self.assertFalse(self.voice.active)
        self.assertEqual(self.voice.history, [])
        self.assertEqual(self.events[-1]['type'], 'chat_ended')

    def test_cancellation_after_remote_result_prevents_fallback(self):
        self.voice.settings['llm']['mode'] = 'online'
        def late_result(*args):
            self.voice.cancel()
            return RAW
        self.voice.remote = SimpleNamespace(decide=late_result)
        with self.assertRaises(Cancelled):
            self.voice.decide('привет', None, {}, self.voice.sequence)
        self.assertEqual(self.voice.local_calls, 0)

    def test_local_synthesis_does_not_run_llm_again(self):
        self.voice.speech_sequence = 4
        self.voice._synthesize(4, 'Готово')
        speech = [event for event in self.events if event['type'] == 'speech'][-1]
        self.assertTrue(speech['local'])
        self.assertEqual(speech['id'], 4)
        self.assertEqual(self.voice.local_calls, 0)

    def test_old_speech_generation_cannot_emit(self):
        self.voice.speech_sequence = 5
        with self.assertRaises(Cancelled):
            self.voice._synthesize(4, 'Старый ответ')
        self.assertFalse(any(event['type'] == 'speech' for event in self.events))

    def test_listen_uses_configured_timeout_and_cancel_invalidates_pending_speech(self):
        self.voice.settings['conversation']['silence_timeout_seconds'] = 35
        self.voice.settings['audio']['end_silence_seconds'] = 2
        self.voice.command({'type': 'listen'})
        self.assertEqual(self.voice.capture.silence_timeout, 35)
        self.assertEqual(self.voice.capture.end_silence, 2)
        old = self.voice.speech_sequence
        self.voice.cancel()
        self.assertIsNone(self.voice.capture)
        self.assertGreater(self.voice.speech_sequence, old)

    def test_old_bridge_commands_cannot_reopen_cancelled_chat(self):
        self.voice.command({'type': 'cancel', 'client_generation': 3})
        sequence = self.voice.sequence
        self.voice.command({'type': 'text', 'text': 'устарело', 'client_generation': 2})
        self.assertFalse(self.voice.active)
        self.assertEqual(self.voice.sequence, sequence)
        self.assertTrue(self.voice.requests.empty())
        self.voice.command({'type': 'text', 'text': 'новый запрос', 'client_generation': 4})
        self.assertTrue(self.voice.active)
        self.assertEqual(self.events[-1]['client_generation'], 4)

    def test_old_silence_expiry_cannot_end_new_activation(self):
        sequence = self.voice.sequence
        self.voice.activate()
        self.voice.end_chat('silence', expected_sequence=sequence)
        self.assertTrue(self.voice.active)

    def test_failed_remote_synthesis_only_falls_back_speech(self):
        self.voice.settings['tts']['mode'] = 'online'
        def unavailable(*args):
            raise ProviderError('http_401')
        self.voice.remote = SimpleNamespace(synthesize=unavailable)
        self.voice._synthesize(self.voice.speech_sequence, 'Готовый ответ')
        self.assertEqual(self.voice.local_calls, 0)
        self.assertTrue(self.events[-1]['local'])
        self.assertTrue(self.events[-2]['fallback'])

    def test_invalid_audio_falls_back_without_repeating_llm_or_exposing_body(self):
        self.voice.settings['tts'].update(mode='online', response_format='pcm')
        def invalid_audio(text, timeout, cancelled):
            return _speech_audio(b'{"error":"private-service-body"}', 'audio/pcm',
                                  self.voice.settings['tts'], cancelled, 16_000_000)
        self.voice.remote = SimpleNamespace(synthesize=invalid_audio)
        self.voice._synthesize(self.voice.speech_sequence, 'Готовый ответ')
        self.assertEqual(self.voice.local_calls, 0)
        self.assertTrue(self.events[-1]['local'])
        self.assertEqual(self.events[-2]['reason'], 'invalid_audio')
        self.assertNotIn('private-service-body', json.dumps(self.events))

    def test_cancelled_synthesis_does_not_emit_audio_or_local_fallback(self):
        self.voice.settings['tts']['mode'] = 'online'
        def obsolete_audio(*args):
            self.voice.cancel()
            return b'result-from-cancelled-request'
        self.voice.remote = SimpleNamespace(synthesize=obsolete_audio)
        with self.assertRaises(Cancelled):
            self.voice._synthesize(self.voice.speech_sequence, 'Старый ответ')
        self.assertEqual(self.voice.local_calls, 0)
        self.assertFalse(any(e['type'] in ('speech', 'metric') for e in self.events))

    def test_captured_end_command_never_waits_for_online_transcription(self):
        self.voice.settings['stt']['mode'] = 'online'
        self.voice.sf = SimpleNamespace(read=lambda *args, **kwargs: ([0.0], 16000))
        self.voice.transcribe = lambda samples: 'Джарвис, закончили!'
        def must_not_contact_service(*args):
            self.fail('An end-chat command reached the online recognizer')
        self.voice.remote = SimpleNamespace(transcribe=must_not_contact_service)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'command.wav'
            path.write_bytes(b'local-control-fixture')
            self.assertIsNone(self.voice.decide(None, str(path), {}, self.voice.sequence))
        self.assertEqual(self.events[-1]['type'], 'chat_ended')
        self.assertFalse(self.voice.active)
