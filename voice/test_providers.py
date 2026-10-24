import io
import json
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time
import unittest
import wave
from unittest.mock import patch

from configuration import load_config
from providers import Cancelled, ProviderError, RemoteClient, route


class ProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                owner = self.server
                body = self.rfile.read(int(self.headers['Content-Length']))
                owner.requests.append((self.path, self.headers.get('Content-Type'), body))
                status, payload, delay, headers = owner.responses.pop(0)
                time.sleep(delay)
                try:
                    self.send_response(status)
                    self.send_header('Content-Type', headers.get('Content-Type', 'application/json'))
                    for key, value in headers.items():
                        if key != 'Content-Type':
                            self.send_header(key, value)
                    self.end_headers()
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.server.requests = []
        self.server.responses = []
        self.config = load_config()
        self.config['llm'].update(mode='online', model='chosen', api_key='secret-test',
            base_url=f'http://127.0.0.1:{self.server.server_port}')
        self.config['network'].update(timeout_seconds=.3, total_timeout_seconds=.8, retry_delay_seconds=.01)
        self.client = RemoteClient(self.config)
        self.metrics = []

    def request(self, cancelled=lambda: False):
        return route('llm', self.config,
            lambda timeout: self.client.json('llm', '/chat/completions', {'model': 'chosen'}, timeout, cancelled),
            lambda: 'local', cancelled, lambda **event: self.metrics.append(event))

    def respond(self, status, body=b'{"reply":"online"}', delay=0, headers=None):
        self.server.responses.append((status, body, delay, headers or {}))

    def test_success_and_transient_retry_return_online_result(self):
        self.respond(503)
        self.respond(200)
        self.assertEqual(self.request(), {'reply': 'online'})
        self.assertEqual(len(self.server.requests), 2)
        self.assertEqual(self.metrics[-1]['attempts'], 2)
        self.assertFalse(self.metrics[-1]['fallback'])

    def test_auth_failure_falls_back_once_without_leaking_response(self):
        self.respond(401, b'{"error":"secret-test invalid"}')
        self.assertEqual(self.request(), 'local')
        self.assertEqual(len(self.server.requests), 1)
        self.assertTrue(self.metrics[-1]['fallback'])
        self.assertNotIn('secret-test', json.dumps(self.metrics))

    def test_offline_and_missing_credentials_make_no_network_request(self):
        self.config['llm']['mode'] = 'offline'
        self.assertEqual(self.request(), 'local')
        self.config['llm']['mode'] = 'online'
        self.config['llm']['api_key'] = ''
        self.assertEqual(self.request(), 'local')
        self.assertEqual(self.server.requests, [])

    def test_malformed_response_and_redirect_fall_back(self):
        for status, body in ((200, b'not json'), (302, b'')):
            self.respond(status, body, headers={'Location': 'https://example.com'})
            self.assertEqual(self.request(), 'local')
        self.assertEqual(len(self.server.requests), 2)

    def test_deadline_bounds_slow_service_and_falls_back(self):
        self.config['network'].update(total_timeout_seconds=.15, timeout_seconds=.15, max_retries=0)
        self.respond(200, delay=.6)
        started = time.monotonic()
        self.assertEqual(self.request(), 'local')
        self.assertLess(time.monotonic() - started, .5)

    def test_cancellation_during_io_does_not_retry_or_fall_back(self):
        self.respond(200, delay=.6)
        started = time.monotonic()
        with self.assertRaises(Cancelled):
            self.request(lambda: time.monotonic() - started > .06)
        self.assertLess(time.monotonic() - started, .4)
        self.assertEqual(self.metrics, [])

    def test_cancellation_during_retry_after_does_not_start_second_attempt(self):
        self.respond(429, headers={'Retry-After': '5'})
        started = time.monotonic()
        with self.assertRaises(Cancelled):
            self.request(lambda: time.monotonic() - started > .06)
        self.assertEqual(len(self.server.requests), 1)

    def test_response_size_is_bounded(self):
        self.respond(200, b'x' * 200)
        with self.assertRaises(ProviderError):
            self.client.request('llm', '/chat/completions', b'{}', 'application/json', .3, lambda: False, limit=100)

    def test_openrouter_and_openai_transcription_have_their_actual_wire_formats(self):
        self.config['stt'].update(self.config['llm'])
        for api_format in ('openrouter', 'openai'):
            self.config['stt']['api_format'] = api_format
            self.respond(200, '{"text":"список книг"}'.encode())
            self.assertEqual(self.client.transcribe(b'RIFF-test-wave', .3, lambda: False), 'список книг')
            path, content_type, body = self.server.requests[-1]
            self.assertEqual(path, '/audio/transcriptions')
            if api_format == 'openrouter':
                self.assertEqual(json.loads(body)['input_audio']['format'], 'wav')
            else:
                self.assertTrue(content_type.startswith('multipart/form-data; boundary='))
                self.assertIn(b'RIFF-test-wave', body)
                self.assertIn(b'name="file"', body)

    def test_synthesis_accepts_audio_and_rejects_json_error_disguised_as_success(self):
        self.config['tts'].update(self.config['llm'], voice='configured', response_format='mp3')
        audio = (Path(__file__).resolve().parent.parent / 'tests/fixtures/tts/tone.mp3').read_bytes()
        self.respond(200, audio, headers={'Content-Type': 'audio/mpeg'})
        self.assertEqual(self.client.synthesize('Готово', .3, lambda: False), audio)
        self.assertEqual(self.server.requests[-1][0], '/audio/speech')
        self.respond(200, b'{"error":"private"}')
        with self.assertRaises(ProviderError):
            self.client.synthesize('Готово', .3, lambda: False)

    def test_pcm_response_becomes_playable_wav_using_headers_or_config(self):
        self.config['tts'].update(self.config['llm'], voice='Gero', response_format='pcm',
                                  pcm_sample_rate_hz=16000, pcm_channels=1)
        for header, rate, channels in (('audio/pcm;rate=24000;channels=2', 24000, 2),
                                        ('application/octet-stream', 16000, 1)):
            with self.subTest(header=header):
                pcm = b'\x00\x10\x00\xf0' * 100
                self.respond(200, pcm, headers={'Content-Type': header})
                result = self.client.synthesize('Проверка', .3, lambda: False)
                with wave.open(io.BytesIO(result)) as audio:
                    self.assertEqual((audio.getframerate(), audio.getnchannels(), audio.getsampwidth()),
                                     (rate, channels, 2))
                    self.assertEqual(audio.readframes(audio.getnframes()), pcm)
                payload = json.loads(self.server.requests[-1][2])
                self.assertEqual(payload['response_format'], 'pcm')
                self.assertNotIn('pcm_sample_rate_hz', payload)
                self.assertNotIn('pcm_channels', payload)

    def test_pcm_rejects_bad_metadata_and_incomplete_frames(self):
        self.config['tts'].update(self.config['llm'], voice='Gero', response_format='pcm')
        for header, body in (('audio/pcm;rate=0', b'\x01\x02'),
                             ('audio/pcm;rate=24000;rate=48000', b'\x01\x02'),
                             ('audio/pcm;channels=3', b'\x01\x02'),
                             ('audio/pcm;bits=24', b'\x01\x02'),
                             ('audio/L16;rate=24000', b'\x01\x02'),
                             ('audio/pcm', b'\x01')):
            with self.subTest(header=header, body=body):
                self.respond(200, body, headers={'Content-Type': header})
                with self.assertRaises(ProviderError):
                    self.client.synthesize('Проверка', .3, lambda: False)

    def test_all_selected_formats_reach_provider_unchanged(self):
        fixture = Path(__file__).resolve().parent.parent / 'tests/fixtures/tts'
        self.config['tts'].update(self.config['llm'], voice='chosen')
        for name, mime in (('mp3', 'audio/mpeg'), ('pcm', 'audio/pcm'), ('opus', 'audio/ogg'),
                           ('wav', 'audio/wav'), ('flac', 'audio/flac'), ('aac', 'audio/aac')):
            with self.subTest(name=name):
                self.config['tts']['response_format'] = name
                self.respond(200, (fixture / f'tone.{name}').read_bytes(), headers={'Content-Type': mime})
                try:
                    audio = self.client.synthesize('Готово', .5, lambda: False)
                    self.assertTrue(audio)
                except ProviderError as error:
                    if error.code != 'audio_decoder_unavailable':
                        raise
                self.assertEqual(json.loads(self.server.requests[-1][2])['response_format'], name)

    def test_conversion_is_inside_request_deadline_and_aborted_on_timeout(self):
        self.config['tts'].update(self.config['llm'], voice='chosen', response_format='pcm')
        self.respond(200, b'\x01\x02', headers={'Content-Type': 'audio/pcm'})
        stopped = threading.Event()
        def slow_conversion(body, mime, settings, cancelled, limit):
            while not cancelled():
                time.sleep(.005)
            stopped.set()
            raise Cancelled()
        with patch('providers._speech_audio', slow_conversion):
            with self.assertRaises(ProviderError) as error:
                self.client.synthesize('Проверка', .05, lambda: False)
            self.assertEqual(error.exception.code, 'timeout')
            self.assertTrue(stopped.wait(.5))
