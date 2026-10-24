"""Bounded, cancellable HTTP adapters. Model inference never executes actions."""
import base64
from datetime import datetime, timezone
from email.message import Message
from email.utils import parsedate_to_datetime
import http.client
import io
import json
import socket
import threading
import time
from urllib.parse import urlsplit
import uuid
import wave

from configuration import DEFAULTS


class Cancelled(Exception):
    pass


class ProviderError(Exception):
    def __init__(self, code, retryable=False, retry_after=0):
        super().__init__(code)
        self.code, self.retryable, self.retry_after = code, retryable, retry_after


def check_cancel(cancelled):
    if cancelled():
        raise Cancelled()


def _wait(seconds, cancelled):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        check_cancel(cancelled)
        time.sleep(min(.025, max(0, end - time.monotonic())))
    check_cancel(cancelled)


def route(stage, config, remote, local, cancelled, report=lambda **event: None):
    started = time.monotonic()
    settings, policy = config[stage], config['network']
    attempts, reason, online = 0, '', False
    check_cancel(cancelled)
    if settings['mode'] == 'online':
        deadline = started + policy['total_timeout_seconds']
        for attempt in range(policy['max_retries'] + 1):
            check_cancel(cancelled)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                reason = 'timeout'
                break
            attempts += 1
            try:
                result = remote(min(policy['timeout_seconds'], remaining))
                check_cancel(cancelled)
                online = True
                break
            except ProviderError as error:
                reason = error.code
                if not error.retryable or attempt == policy['max_retries']:
                    break
                delay = max(error.retry_after, policy['retry_delay_seconds'] * (2 ** attempt))
                _wait(min(delay, max(0, deadline - time.monotonic())), cancelled)
    if not online:
        check_cancel(cancelled)
        result = local()
        check_cancel(cancelled)
    report(stage=stage, provider=settings['model'] if online else DEFAULTS[stage]['model'],
           mode='online' if online else 'offline', fallback=settings['mode'] == 'online' and not online,
           reason=reason, attempts=attempts, elapsed=round(time.monotonic() - started, 3))
    return result


def _retry_after(value):
    try:
        return max(0, min(180, float(value)))
    except (TypeError, ValueError):
        try:
            return max(0, min(180, (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds()))
        except (TypeError, ValueError, OverflowError):
            return 0


def _pcm_wave(body, rate, channels, limit):
    if not body or len(body) % (channels * 2):
        raise ProviderError('invalid_audio')
    if len(body) + 44 > limit:
        raise ProviderError('response_size')
    output = io.BytesIO()
    with wave.open(output, 'wb') as audio:
        audio.setparams((channels, 2, rate, 0, 'NONE', 'not compressed'))
        audio.writeframes(body)
    return output.getvalue()


def _decode_opus(body, cancelled, limit):
    try:
        import soundfile as sf
    except (ImportError, OSError):
        raise ProviderError('audio_decoder_unavailable') from None
    try:
        with sf.SoundFile(io.BytesIO(body)) as audio:
            if audio.format != 'OGG' or audio.subtype != 'OPUS' or audio.channels not in (1, 2):
                raise ProviderError('invalid_audio')
            if not 8000 <= audio.samplerate <= 96000 or audio.frames <= 0:
                raise ProviderError('invalid_audio')
            if audio.frames * audio.channels * 2 + 44 > limit:
                raise ProviderError('response_size')
            pcm = bytearray()
            while True:
                check_cancel(cancelled)
                chunk = audio.buffer_read(4096, dtype='int16')
                if not chunk:
                    break
                if len(pcm) + len(chunk) + 44 > limit:
                    raise ProviderError('response_size')
                pcm.extend(chunk)
            if len(pcm) != audio.frames * audio.channels * 2:
                raise ProviderError('invalid_audio')
            result = _pcm_wave(pcm, audio.samplerate, audio.channels, limit)
    except (RuntimeError, ValueError, OSError):
        raise ProviderError('invalid_audio') from None
    check_cancel(cancelled)
    return result


def _valid_container(body, name):
    if name == 'mp3':
        offset = 0
        if body.startswith(b'ID3'):
            if len(body) < 10 or any(byte >= 128 for byte in body[6:10]):
                return False
            offset = 10 + sum(byte << shift for byte, shift in zip(body[6:10], (21, 14, 7, 0)))
            if body[3] == 4 and body[5] & 16:
                offset += 10
        frame = body[offset:offset + 4]
        return (len(frame) == 4 and frame[0] == 255 and frame[1] & 0xE6 == 0xE2
                and frame[1] & 0x18 != 0x08 and frame[2] & 0xF0 != 0xF0 and frame[2] & 12 != 12)
    if name == 'aac':
        offset = 0
        while offset < len(body):
            frame = body[offset:offset + 7]
            if len(frame) < 7 or frame[0] != 255 or frame[1] & 0xF6 != 0xF0:
                return False
            size = ((frame[3] & 3) << 11) | (frame[4] << 3) | (frame[5] >> 5)
            if size < (7 if frame[1] & 1 else 9) or offset + size > len(body):
                return False
            offset += size
        return offset > 0
    if name == 'flac':
        return len(body) >= 42 and body[:4] == b'fLaC' and body[4] & 127 == 0 and body[5:8] == b'\x00\x00\x22'
    if name == 'wav':
        try:
            with wave.open(io.BytesIO(body)) as audio:
                size = audio.getnframes() * audio.getnchannels() * audio.getsampwidth()
                return 0 < size <= len(body) and len(audio.readframes(audio.getnframes())) == size
        except (wave.Error, EOFError):
            return False
    return False


def _speech_audio(body, content_type, settings, cancelled, limit):
    check_cancel(cancelled)
    if not body or len(body) > limit:
        raise ProviderError('response_size')
    name = settings['response_format']
    header = Message()
    header['Content-Type'] = content_type
    allowed = {'mp3': ('audio/mpeg', 'audio/mp3', 'audio/x-mp3'),
               'pcm': ('audio/pcm', 'audio/x-pcm'),
               'opus': ('audio/ogg', 'audio/opus', 'application/ogg'),
               'wav': ('audio/wav', 'audio/wave', 'audio/x-wav', 'audio/vnd.wave'),
               'flac': ('audio/flac', 'audio/x-flac'),
               'aac': ('audio/aac', 'audio/aacp', 'audio/x-aac')}
    if header.get_content_type().lower() not in (*allowed[name], 'application/octet-stream'):
        raise ProviderError('invalid_audio')
    if name == 'opus':
        if not body.startswith(b'OggS') or b'OpusHead' not in body[:512]:
            raise ProviderError('invalid_audio')
        return _decode_opus(body, cancelled, limit)
    if name != 'pcm':
        if not _valid_container(body, name):
            raise ProviderError('invalid_audio')
        check_cancel(cancelled)
        return body
    if body.startswith((b'RIFF', b'ID3', b'OggS', b'fLaC')) or body.lstrip().lower().startswith((b'<html', b'<!doctype', b'<?xml')):
        raise ProviderError('invalid_audio')
    if body.lstrip().startswith((b'{', b'[')):
        try:
            json.loads(body)
        except (ValueError, UnicodeError):
            pass
        else:
            raise ProviderError('invalid_audio')
    params = {}
    for name, value in header.get_params()[1:]:
        name = name.lower()
        if name in params:
            raise ProviderError('invalid_audio')
        params[name] = value
    for name, expected in (('bits', '16'), ('bit-depth', '16'), ('encoding', 's16le'),
                            ('format', 's16le'), ('endianness', 'little')):
        if name in params and (not isinstance(params[name], str) or params[name].lower() != expected):
            raise ProviderError('invalid_audio')
    try:
        rate = int(params.get('rate', settings['pcm_sample_rate_hz']))
        channels = int(params.get('channels', settings['pcm_channels']))
    except (ValueError, TypeError):
        raise ProviderError('invalid_audio') from None
    if not 8000 <= rate <= 96000 or channels not in (1, 2):
        raise ProviderError('invalid_audio')
    result = _pcm_wave(body, rate, channels, limit)
    check_cancel(cancelled)
    return result


class RemoteClient:
    def __init__(self, config):
        self.config = config

    def request(self, stage, path, payload, content_type, timeout, cancelled, limit=2_000_000, audio=False):
        check_cancel(cancelled)
        settings = self.config[stage]
        if not settings.get('api_key'):
            raise ProviderError('missing_credentials')
        url = urlsplit(settings['base_url'])
        connection_type = http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection
        connection = connection_type(url.hostname, url.port, timeout=timeout)
        done, aborted = threading.Event(), threading.Event()
        outcome = []

        def perform():
            response = None
            try:
                connection.connect()
                if aborted.is_set():
                    return
                connection.request('POST', url.path.rstrip('/') + path, body=payload,
                    headers={'Authorization': 'Bearer ' + settings['api_key'], 'Content-Type': content_type,
                             'Accept': 'audio/*' if audio else 'application/json'})
                response = connection.getresponse()
                if not 200 <= response.status < 300:
                    raise ProviderError(f'http_{response.status}', response.status in (408, 429) or response.status >= 500,
                                        _retry_after(response.getheader('Retry-After')))
                mime = (response.getheader('Content-Type') or '').split(';')[0].strip().lower()
                if audio and not (mime.startswith('audio/') or mime in ('application/octet-stream', 'application/ogg')):
                    raise ProviderError('invalid_audio')
                if not audio and mime != 'application/json' and not mime.endswith('+json'):
                    raise ProviderError('invalid_response')
                body = response.read(limit + 1)
                if not body or len(body) > limit:
                    raise ProviderError('response_size')
                if audio:
                    body = _speech_audio(body, response.getheader('Content-Type'), settings,
                                         lambda: aborted.is_set() or cancelled(), limit)
                outcome.append(body)
            except Cancelled as error:
                outcome.append(error)
            except ProviderError as error:
                outcome.append(error)
            except (OSError, http.client.HTTPException):
                outcome.append(ProviderError('network_error', retryable=True))
            finally:
                if response is not None:
                    response.close()
                connection.close()
                done.set()

        def abort():
            aborted.set()
            current_socket = connection.sock
            if current_socket:
                try:
                    current_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            connection.close()

        # A provider blocked in DNS or I/O must not block local chat cancellation.
        threading.Thread(target=perform, daemon=True).start()
        deadline = time.monotonic() + timeout
        try:
            while not done.wait(.025):
                check_cancel(cancelled)
                if time.monotonic() >= deadline:
                    raise ProviderError('timeout', retryable=True)
            check_cancel(cancelled)
            if not outcome:
                raise ProviderError('network_error', retryable=True)
            if isinstance(outcome[0], (ProviderError, Cancelled)):
                raise outcome[0]
            return outcome[0]
        finally:
            abort()

    def json(self, stage, path, payload, timeout, cancelled, content_type='application/json'):
        data = json.dumps(payload, ensure_ascii=False).encode() if isinstance(payload, dict) else payload
        raw = self.request(stage, path, data, content_type, timeout, cancelled)
        try:
            result = json.loads(raw)
            if not isinstance(result, dict) or 'error' in result:
                raise ValueError()
            return result
        except (ValueError, UnicodeError):
            raise ProviderError('invalid_response') from None

    def transcribe(self, audio, timeout, cancelled):
        settings = self.config['stt']
        payload = {'model': settings['model'], 'language': settings['language']}
        content_type = 'application/json'
        if settings['api_format'] == 'openrouter':
            payload['input_audio'] = {'data': base64.b64encode(audio).decode(), 'format': 'wav'}
        else:
            boundary = uuid.uuid4().hex
            parts = []
            for key, value in payload.items():
                parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="utterance.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
                         + audio + f'\r\n--{boundary}--\r\n'.encode())
            payload = b''.join(parts)
            content_type = 'multipart/form-data; boundary=' + boundary
        result = self.json('stt', '/audio/transcriptions', payload, timeout, cancelled, content_type)
        text = result.get('text')
        if not isinstance(text, str) or not text.strip() or len(text) > 5000:
            raise ProviderError('invalid_transcript')
        return text.strip()[:1500]

    def decide(self, messages, schema, timeout, cancelled):
        settings = self.config['llm']
        payload = {'model': settings['model'], 'messages': messages, 'max_tokens': settings['max_tokens'],
                   'temperature': 0, 'stream': False}
        format_name = settings['response_format']
        if format_name != 'text':
            payload['response_format'] = {'type': format_name}
            if format_name == 'json_schema':
                payload['response_format']['json_schema'] = {'name': 'assistant_decision', 'strict': True, 'schema': schema}
        result = self.json('llm', '/chat/completions', payload, timeout, cancelled)
        try:
            text = result['choices'][0]['message']['content']
            if not isinstance(text, str) or not text or len(text) > 20000:
                raise ValueError()
            return text
        except (KeyError, IndexError, TypeError, ValueError):
            raise ProviderError('invalid_decision') from None

    def synthesize(self, text, timeout, cancelled):
        settings = self.config['tts']
        payload = {'model': settings['model'], 'input': text, 'voice': settings['voice'],
                   'response_format': settings['response_format']}
        return self.request('tts', '/audio/speech', json.dumps(payload, ensure_ascii=False).encode(),
                            'application/json', timeout, cancelled, limit=16_000_000, audio=True)
