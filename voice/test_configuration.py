import json
from pathlib import Path
import tempfile
import unittest

from configuration import ConfigError, load_config, public_settings


class ConfigurationTests(unittest.TestCase):
    def load(self, value):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'config.json'
            path.write_text(json.dumps(value))
            return load_config(path)

    def test_no_config_preserves_offline_engines(self):
        config = load_config(None)
        self.assertEqual([config[s]['model'] for s in ('stt', 'llm', 'tts')], ['whisper', 'gemma', 'macos'])
        self.assertTrue(all(config[s]['mode'] == 'offline' for s in ('stt', 'llm', 'tts')))

    def test_tts_formats_preserve_mp3_default_and_validate_pcm_settings(self):
        self.assertEqual(load_config()['tts']['response_format'], 'mp3')
        for name in ('mp3', 'pcm', 'opus', 'wav', 'flac', 'aac'):
            with self.subTest(name=name):
                config = self.load({'tts': {'response_format': name, 'pcm_sample_rate_hz': 48000, 'pcm_channels': 2}})
                self.assertEqual(config['tts']['response_format'], name)
                self.assertEqual(config['tts']['pcm_sample_rate_hz'], 48000)
                self.assertEqual(config['tts']['pcm_channels'], 2)
        for field, values in {'response_format': ('auto', 'MP3', '', None, 1),
                              'pcm_sample_rate_hz': (True, 7999, 96001, 24000.5, None),
                              'pcm_channels': (True, 0, 3, 1.5, None)}.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ConfigError):
                    self.load({'tts': {field: value}})

    def test_rejects_wrong_types_unknown_fields_and_unbounded_settings(self):
        for value in ({'version': True}, {'typo': 1}, {'audio': {'end_silence_seconds': -1}},
                      {'network': {'max_retries': 20}}, {'conversation': {'silence_timeout_seconds': float('nan')}},
                      {'stt': {'mode': 'offline', 'model': 'new-engine'}}, {'audio': {'voice_processing': 'true'}}):
            with self.subTest(value=value), self.assertRaises(ConfigError):
                self.load(value)

    def test_remote_credentials_require_https_and_cannot_be_in_url(self):
        for url in ('http://example.com/v1', 'https://secret@example.com/v1', 'https://example.com/v1?key=secret'):
            with self.subTest(url=url), self.assertRaises(ConfigError) as error:
                self.load({'llm': {'mode': 'online', 'model': 'chosen', 'base_url': url}})
            self.assertNotIn('secret', str(error.exception))

    def test_credentials_are_loaded_relative_to_config_and_not_in_public_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'config.json'
            (Path(folder) / 'key.txt').write_text('private-test-key\n')
            path.write_text(json.dumps({'llm': {'mode': 'online', 'model': 'chosen',
                'base_url': 'https://openrouter.ai/api/v1', 'api_key_file': 'key.txt'}}))
            config = load_config(path)
        self.assertEqual(config['llm']['api_key'], 'private-test-key')
        summary = json.dumps(public_settings(config))
        self.assertNotIn('private-test-key', summary)
        self.assertNotIn('key.txt', summary)
        self.assertNotIn('api_key', summary)

    def test_empty_credentials_are_a_runtime_fallback_not_a_config_failure(self):
        config = self.load({'tts': {'mode': 'online', 'model': 'chosen', 'voice': 'chosen',
            'base_url': 'https://openrouter.ai/api/v1'}})
        self.assertEqual(config['tts']['api_key'], '')

    def test_online_stage_requires_endpoint_and_model(self):
        with self.assertRaises(ConfigError):
            self.load({'llm': {'mode': 'online'}})

    def test_configurable_timeouts_are_independent(self):
        config = self.load({'conversation': {'silence_timeout_seconds': 40}, 'audio': {'end_silence_seconds': 2}})
        self.assertEqual(config['conversation']['silence_timeout_seconds'], 40)
        self.assertEqual(config['audio']['end_silence_seconds'], 2)

    def test_invalid_key_encoding_is_a_sanitized_configuration_error(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'config.json'
            (Path(folder) / 'key.bin').write_bytes(b'\xff\xfe')
            path.write_text(json.dumps({'llm': {'mode': 'online', 'model': 'chosen',
                'base_url': 'https://example.com/v1', 'api_key_file': 'key.bin'}}))
            with self.assertRaises(ConfigError) as error:
                load_config(path)
            self.assertIn('api_key_file', str(error.exception))

    def test_offline_stage_does_not_need_its_unused_remote_credential_file(self):
        config = self.load({'llm': {'mode': 'offline', 'model': 'gemma', 'api_key_file': 'not-installed.key'}})
        self.assertEqual(config['llm']['model'], 'gemma')
