"""Small, independently testable boundary between model output and the app."""
import json
import re

ACTIONS = {"chat", "list_books", "play", "pause", "resume", "restart", "confirm", "cancel", "where_stopped", "last_book"}


def confirmation_intent(text):
    words = re.findall(r"[^\W\d_]+", text.lower())
    if words and words[0] in {"джарвис", "джарвиз", "жарвис", "jarvis"}:
        words.pop(0)
    text = " ".join(words)
    if text in {"да", "давай", "да начинай", "подтверждаю", "да подтверждаю", "начинай сначала", "да сначала", "да начни сначала"}:
        return "confirm"
    if text in {"нет", "отмена", "не надо", "не начинай", "нет не надо", "нет отмена"}:
        return "cancel"
    return None


def parse_decision(raw, context):
    try:
        result, _ = json.JSONDecoder().raw_decode(raw[raw.index("{"):])
    except (ValueError, json.JSONDecodeError) as error:
        raise ValueError("Модель не вернула понятный ответ. Попробуй сказать иначе.") from error
    if not isinstance(result, dict) or not isinstance(result.get("action"), str) or result["action"] not in ACTIONS:
        raise ValueError("Неизвестное действие. Ничего не выполнено.")
    reply = result.get("reply", "")
    if not isinstance(reply, str) or (result["action"] == "chat" and not reply.strip()):
        raise ValueError("Пустой ответ. Повтори, пожалуйста.")
    heard = result.get("heard", "")
    if not isinstance(heard, str):
        raise ValueError("Не удалось разобрать запрос.")
    if context.get("pending_restart") and (intent := confirmation_intent(heard)):
        result["action"] = intent
        result["book_id"] = None
    book_id = result.get("book_id") or None
    known = {book["id"] for book in context.get("books", [])}
    if book_id is not None and (not isinstance(book_id, str) or book_id not in known):
        raise ValueError("Не нашёл такую книгу. Скажи: список книг.")
    if result["action"] == "confirm" and not context.get("pending_restart"):
        raise ValueError("Сейчас нечего подтверждать.")
    page = result.get("page", 0)
    if not isinstance(heard, str) or type(page) is not int or not 0 <= page <= 10000:
        raise ValueError("Не удалось разобрать запрос.")
    return {"action": result["action"], "book_id": book_id, "reply": reply.strip()[:1200], "heard": heard[:1500], "page": page}


def heard_wake(text):
    return bool(re.search(r"\b(?:джарвис|джарвиз|жарвис|jarvis)\b", text.lower()))


def end_chat_intent(text, phrases=None):
    def words(value):
        return ' '.join(re.findall(r'[^\W\d_]+', value.lower()))
    normalized = words(text)
    parts = normalized.split()
    # Tiny Whisper renders the wake prefix as «Джарлис» in the recorded control check.
    if parts and parts[0] in {'джарвис', 'джарвиз', 'жарвис', 'джарлис', 'jarvis'}:
        normalized = ' '.join(parts[1:])
    commands = phrases if phrases is not None else ['закончили', 'конец разговора', 'заверши разговор', 'end chat']
    return bool(normalized) and normalized in {words(phrase) for phrase in commands}


class Capture:
    def __init__(self, now, initial=b"", initial_voice=False, *, silence_timeout=15, end_silence=1.0, max_seconds=28):
        self.started = self.last_voice = now
        self.audio = bytearray(initial)
        self.has_voice = initial_voice
        self.expired = False
        self.silence_timeout = silence_timeout
        self.end_silence = end_silence
        self.max_bytes = int(max_seconds * 32000)

    def feed(self, pcm, voiced, now):
        self.audio.extend(pcm)
        if voiced:
            self.last_voice = now
            self.has_voice = True
        if not self.has_voice:
            # Keep memory bounded while waiting for the first spoken word.
            self.audio = self.audio[-16000:]
            self.expired = now - self.started > self.silence_timeout
            return None
        if now - self.last_voice > self.end_silence or len(self.audio) >= self.max_bytes:
            return bytes(self.audio[:self.max_bytes])
        return None
