import unittest
from logic import parse_decision, heard_wake, Capture


class VoiceTests(unittest.TestCase):
    def test_only_known_actions_and_books_can_cross_boundary(self):
        for raw in ['{"action":"shell","reply":"ok"}', '{"action":"play","book_id":"invented","reply":"ok"}']:
            with self.assertRaises(ValueError):
                parse_decision(raw, {"books": [{"id": "real"}]})

    def test_json_reply_can_contain_braces(self):
        result = parse_decision('```json\n{"action":"chat","reply":"Символы { и }.","heard":"вопрос"}\n```', {})
        self.assertEqual(result["reply"], "Символы { и }.")

    def test_confirm_requires_pending_restart(self):
        with self.assertRaises(ValueError):
            parse_decision('{"action":"confirm","reply":"да"}', {})

    def test_explicit_yes_resolves_pending_restart_even_if_model_repeats_action(self):
        result = parse_decision('{"action":"restart","reply":"","heard":"Джарвис, да"}', {"pending_restart": "book"})
        self.assertEqual(result["action"], "confirm")

    def test_explicit_no_cancels_pending_restart(self):
        result = parse_decision('{"action":"chat","reply":"хорошо","heard":"Нет, не надо"}', {"pending_restart": "book"})
        self.assertEqual(result["action"], "cancel")

    def test_russian_and_english_wake_word(self):
        self.assertTrue(heard_wake("Джарвис, продолжи книгу"))
        self.assertTrue(heard_wake("Jarvis!"))
        self.assertFalse(heard_wake("Включи следующую главу"))

    def test_silence_does_not_become_a_request(self):
        capture = Capture(now=0)
        self.assertIsNone(capture.feed(b"\0" * 3200, voiced=False, now=16))
        self.assertTrue(capture.expired)

    def test_voice_then_silence_submits_one_utterance(self):
        capture = Capture(now=0)
        self.assertIsNone(capture.feed(b"a" * 3200, voiced=True, now=.2))
        result = capture.feed(b"\0" * 3200, voiced=False, now=1.5)
        self.assertTrue(result.startswith(b"a"))


if __name__ == "__main__":
    unittest.main()
