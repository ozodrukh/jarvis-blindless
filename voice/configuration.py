"""Versioned private settings. Never include this dictionary in bridge events."""
from copy import deepcopy
import json
import math
import os
from pathlib import Path
from urllib.parse import urlsplit


class ConfigError(ValueError):
    pass


DEFAULTS = {
    'version': 1,
    'stt': {'mode': 'offline', 'model': 'whisper', 'language': 'ru', 'api_format': 'openrouter'},
    'llm': {'mode': 'offline', 'model': 'gemma', 'response_format': 'json_schema', 'max_tokens': 768},
    'tts': {'mode': 'offline', 'model': 'macos', 'voice': '', 'local_voice': '', 'language': 'ru-RU',
            'response_format': 'mp3', 'pcm_sample_rate_hz': 24000, 'pcm_channels': 1},
    'network': {'timeout_seconds': 8, 'total_timeout_seconds': 18, 'max_retries': 1, 'retry_delay_seconds': 0.5},
    'audio': {'speech_threshold': 0.0008, 'wake_threshold': 0.0005, 'vad_threshold': 0.4,
              'end_silence_seconds': 1.2, 'max_utterance_seconds': 28, 'wake_interval_seconds': 0.8,
              'normalize_gain_limit': 12, 'target_rms': 0.035, 'voice_processing': True},
    'conversation': {'silence_timeout_seconds': 15,
                     'end_phrases': ['закончили', 'конец разговора', 'заверши разговор', 'end chat']},
}


def _fail(field):
    # Field names here are constants, never raw user values or provider bodies.
    raise ConfigError(f'Проверьте поле {field} в файле настроек.')


def _object(value, allowed, field):
    if not isinstance(value, dict) or set(value) - set(allowed):
        _fail(field)


def _number(value, low, high, field, integer=False):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        _fail(field)
    if integer and type(value) is not int:
        _fail(field)


def _string(value, field, maximum=300, empty=False):
    if not isinstance(value, str) or len(value) > maximum or (not empty and not value.strip()) or any(ord(c) < 32 for c in value):
        _fail(field)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            _fail('JSON (повторяющийся ключ)')
        result[key] = value
    return result


def load_config(path=None):
    config = deepcopy(DEFAULTS)
    supplied = {}
    if path:
        try:
            source = Path(path).expanduser().resolve()
            if not source.is_file():
                _fail('JSON (нужен обычный файл)')
            with source.open('rb') as file:
                raw = file.read(65537)
            if len(raw) > 65536:
                _fail('JSON (размер файла)')
            supplied = json.loads(raw, object_pairs_hook=_unique_object)
        except (OSError, ValueError, UnicodeError) as error:
            if isinstance(error, ConfigError):
                raise
            raise ConfigError('Не удалось прочитать JSON-настройки. Выберите доступный файл JSON.') from None
    _object(supplied, DEFAULTS, 'JSON')
    if type(supplied.get('version', 1)) is not int or supplied.get('version', 1) != 1:
        _fail('version')
    for section in ('network', 'audio', 'conversation'):
        values = supplied.get(section, {})
        _object(values, DEFAULTS[section], section)
        config[section].update(values)
    ranges = {
        'network': {'timeout_seconds': (.1, 120), 'total_timeout_seconds': (.1, 180),
                    'max_retries': (0, 5), 'retry_delay_seconds': (0, 10)},
        'audio': {'speech_threshold': (.00001, .1), 'wake_threshold': (.00001, .1), 'vad_threshold': (.1, .99),
                  'end_silence_seconds': (.3, 5), 'max_utterance_seconds': (3, 28), 'wake_interval_seconds': (.3, 3),
                  'normalize_gain_limit': (1, 20), 'target_rms': (.005, .1)},
        'conversation': {'silence_timeout_seconds': (1, 600)},
    }
    for section, fields in ranges.items():
        for name, (low, high) in fields.items():
            _number(config[section][name], low, high, f'{section}.{name}', name == 'max_retries')
    if type(config['audio']['voice_processing']) is not bool:
        _fail('audio.voice_processing')
    phrases = config['conversation']['end_phrases']
    if not isinstance(phrases, list) or not 1 <= len(phrases) <= 20:
        _fail('conversation.end_phrases')
    for phrase in phrases:
        _string(phrase, 'conversation.end_phrases', maximum=80)
    common = {'mode', 'model', 'base_url', 'api_key', 'api_key_env', 'api_key_file'}
    for stage in ('stt', 'llm', 'tts'):
        values = supplied.get(stage, {})
        _object(values, common | set(DEFAULTS[stage]), stage)
        settings = config[stage]
        settings.update(values)
        if settings['mode'] not in ('online', 'offline'):
            _fail(f'{stage}.mode')
        _string(settings['model'], f'{stage}.model')
        if settings['mode'] == 'offline' and settings['model'] != DEFAULTS[stage]['model']:
            _fail(f'{stage}.model (локальная модель)')
        if settings['mode'] == 'online':
            if not values.get('model') or not values.get('base_url'):
                _fail(f'{stage}.model/base_url')
        if settings.get('base_url'):
            _string(settings['base_url'], f'{stage}.base_url', maximum=1000)
            try:
                url = urlsplit(settings['base_url'])
                _ = url.port
                if not url.hostname or url.username or url.password or url.query or url.fragment:
                    _fail(f'{stage}.base_url')
                if url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ('127.0.0.1', 'localhost', '::1')):
                    _fail(f'{stage}.base_url (нужен HTTPS)')
            except ValueError:
                _fail(f'{stage}.base_url')
            settings['base_url'] = settings['base_url'].rstrip('/')
        for field in ('api_key', 'api_key_env', 'api_key_file'):
            _string(settings.get(field, ''), f'{stage}.{field}', maximum=8192, empty=True)
        key = settings.get('api_key', '')
        if settings['mode'] == 'online' and not key and settings.get('api_key_file'):
            try:
                key_path = Path(settings['api_key_file']).expanduser()
                if not key_path.is_absolute():
                    key_path = source.parent / key_path
                if not key_path.is_file():
                    _fail(f'{stage}.api_key_file')
                with key_path.open('r', encoding='utf-8') as file:
                    key = file.read(8193).strip()
            except (OSError, UnicodeError):
                _fail(f'{stage}.api_key_file')
        if settings['mode'] == 'online' and not key:
            key = os.environ.get(settings.get('api_key_env', ''), '')
        _string(key, f'{stage}.api_key', maximum=8192, empty=True)
        settings['api_key'] = key
    if config['stt']['api_format'] not in ('openrouter', 'openai'):
        _fail('stt.api_format')
    for stage in ('stt', 'tts'):
        _string(config[stage]['language'], f'{stage}.language', maximum=30)
    for field in ('voice', 'local_voice'):
        _string(config['tts'][field], f'tts.{field}', empty=True)
    if config['tts']['mode'] == 'online' and not config['tts']['voice']:
        _fail('tts.voice')
    if config['tts']['response_format'] not in ('mp3', 'pcm', 'opus', 'wav', 'flac', 'aac'):
        _fail('tts.response_format')
    _number(config['tts']['pcm_sample_rate_hz'], 8000, 96000, 'tts.pcm_sample_rate_hz', integer=True)
    _number(config['tts']['pcm_channels'], 1, 2, 'tts.pcm_channels', integer=True)
    if config['llm']['response_format'] not in ('json_schema', 'json_object', 'text'):
        _fail('llm.response_format')
    _number(config['llm']['max_tokens'], 64, 2048, 'llm.max_tokens', integer=True)
    return config


def public_settings(config):
    return {**{name: deepcopy(config[name]) for name in ('audio', 'conversation')},
            'stages': {stage: {'mode': config[stage]['mode'], 'model': config[stage]['model']}
                       for stage in ('stt', 'llm', 'tts')},
            'local_voice': config['tts']['local_voice'], 'speech_language': config['tts']['language']}
