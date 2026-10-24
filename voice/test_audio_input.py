"""Regressions for configurable listening and explicit conversation endings."""
import unittest

import logic


class CaptureConfigurationTests(unittest.TestCase):
    def test_initial_silence_uses_configured_short_timeout(self):
        capture = logic.Capture(now=10, silence_timeout=3)

        self.assertIsNone(capture.feed(b"\0" * 3200, voiced=False, now=12.9))
        self.assertFalse(capture.expired)
        self.assertIsNone(capture.feed(b"\0" * 3200, voiced=False, now=13.1))
        self.assertTrue(capture.expired)

    def test_initial_silence_can_wait_longer_than_old_fifteen_second_limit(self):
        capture = logic.Capture(now=0, silence_timeout=30)

        self.assertIsNone(capture.feed(b"\0" * 3200, voiced=False, now=16))
        self.assertFalse(capture.expired)
        self.assertIsNone(capture.feed(b"\0" * 3200, voiced=False, now=30.1))
        self.assertTrue(capture.expired)

    def test_utterance_end_pause_is_independent_of_initial_silence_timeout(self):
        capture = logic.Capture(now=0, silence_timeout=20, end_silence=2)
        speech = b"\x01\0" * 1600
        pause = b"\0" * 3200

        self.assertIsNone(capture.feed(speech, voiced=True, now=1))
        self.assertIsNone(capture.feed(pause, voiced=False, now=2.2))
        self.assertEqual(capture.feed(pause, voiced=False, now=3.1), speech + pause + pause)
        self.assertFalse(capture.expired)

    def test_quiet_pcm_marked_as_speech_is_retained_and_ends_after_short_pause(self):
        capture = logic.Capture(now=0, end_silence=0.25)
        # Very quiet 16-bit PCM: speech detection, rather than a fixed amplitude
        # cutoff inside Capture, decides whether these samples contain speech.
        quiet_speech = b"\x01\0" * 1600
        silence = b"\0" * 3200

        self.assertIsNone(capture.feed(quiet_speech, voiced=True, now=0.1))
        self.assertIsNone(capture.feed(silence, voiced=False, now=0.3))
        self.assertEqual(
            capture.feed(silence, voiced=False, now=0.4),
            quiet_speech + silence + silence,
        )

    def test_maximum_audio_duration_caps_a_continuously_voiced_utterance(self):
        capture = logic.Capture(now=0, end_silence=5, max_seconds=2)
        first_second = b"\x01\0" * 16000
        remaining_audio = b"\x02\0" * 24000

        self.assertIsNone(capture.feed(first_second, voiced=True, now=1))
        result = capture.feed(remaining_audio, voiced=True, now=2.5)

        self.assertEqual(result, first_second + remaining_audio[:32000])
        self.assertEqual(len(result), 2 * 32000)

    def test_silence_never_submits_even_after_audio_duration_limit(self):
        capture = logic.Capture(now=0, silence_timeout=3, max_seconds=1)

        self.assertIsNone(capture.feed(b"\0" * 64000, voiced=False, now=2))
        self.assertFalse(capture.expired)
        self.assertIsNone(capture.feed(b"\0" * 64000, voiced=False, now=4))
        self.assertTrue(capture.expired)

    def test_initial_wake_audio_is_preserved_before_the_spoken_request(self):
        wake_audio = b"\x01\0" * 800
        request_audio = b"\x02\0" * 1600
        silence = b"\0" * 3200
        capture = logic.Capture(now=0, initial=wake_audio, initial_voice=True)

        self.assertIsNone(capture.feed(request_audio, voiced=True, now=0.2))
        self.assertEqual(
            capture.feed(silence, voiced=False, now=1.3),
            wake_audio + request_audio + silence,
        )


class EndChatIntentTests(unittest.TestCase):
    def test_recognizer_wake_prefix_alias_preserves_exact_command_and_negation_guard(self):
        self.assertTrue(logic.end_chat_intent('Джарлис, закончили.'))
        self.assertFalse(logic.end_chat_intent('Джарлис, мы не закончили.'))

    def test_default_end_commands_accept_case_punctuation_and_optional_wake_word(self):
        commands = [
            "закончили",
            "КОНЕЦ РАЗГОВОРА!",
            "Заверши разговор.",
            "end chat",
            "  END CHAT!  ",
            "Джарвис, закончили.",
            "джарвис: конец разговора!",
            "Jarvis, END CHAT.",
        ]

        for text in commands:
            with self.subTest(text=text):
                self.assertTrue(logic.end_chat_intent(text))

    def test_negation_or_mention_inside_a_request_does_not_end_chat(self):
        ordinary_requests = [
            "мы не закончили",
            "Джарвис, мы не закончили!",
            "не заверши разговор",
            "объясни что значит end chat",
            "Jarvis, explain end chat",
            "расскажи про конец разговора",
            "закончили читать главу",
            "end chat tomorrow",
            "",
            "Джарвис!",
        ]

        for text in ordinary_requests:
            with self.subTest(text=text):
                self.assertFalse(logic.end_chat_intent(text))

    def test_configured_phrases_are_exact_commands_with_the_same_normalization(self):
        phrases = ["хватит на сегодня", "stop talking"]

        self.assertTrue(logic.end_chat_intent("Джарвис, хватит на сегодня!", phrases=phrases))
        self.assertTrue(logic.end_chat_intent("Jarvis: STOP TALKING.", phrases=phrases))
        self.assertFalse(logic.end_chat_intent("мы не хотим stop talking", phrases=phrases))


if __name__ == "__main__":
    unittest.main()
