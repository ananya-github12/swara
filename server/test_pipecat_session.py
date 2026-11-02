"""Unit tests for Swara's Pipecat JSON/base64 frame serializer."""

from __future__ import annotations

import asyncio
import base64
import json
import unittest

from pipecat.frames.frames import (
    InputAudioRawFrame,
    InputTransportMessageFrame,
    OutputAudioRawFrame,
    OutputTransportMessageFrame,
)

from pipecat_session import SwaraFrameSerializer


class SwaraFrameSerializerTest(unittest.TestCase):
    def test_audio_chunk_deserializes_to_pcm_input_frame(self) -> None:
        pcm = b"\x00\x00\xff\x7f\x00\x80"
        wire = json.dumps(
            {
                "type": "audio.chunk",
                "data": base64.b64encode(pcm).decode("ascii"),
            }
        )

        frame = asyncio.run(SwaraFrameSerializer().deserialize(wire))

        self.assertIsInstance(frame, InputAudioRawFrame)
        assert isinstance(frame, InputAudioRawFrame)
        self.assertEqual(frame.audio, pcm)
        self.assertEqual(frame.sample_rate, 16_000)
        self.assertEqual(frame.num_channels, 1)

    def test_output_audio_serializes_to_agent_audio_json(self) -> None:
        pcm = b"\x01\x00\x02\x00"
        frame = OutputAudioRawFrame(
            audio=pcm,
            sample_rate=24_000,
            num_channels=1,
        )

        wire = asyncio.run(SwaraFrameSerializer().serialize(frame))

        self.assertIsInstance(wire, str)
        message = json.loads(wire)
        self.assertEqual(
            message,
            {
                "type": "agent.audio",
                "data": base64.b64encode(pcm).decode("ascii"),
                "mimeType": "audio/pcm",
            },
        )

    def test_control_messages_pass_through_in_both_directions(self) -> None:
        inbound = {"type": "page.update", "page": {"title": "Next"}}
        input_frame = asyncio.run(
            SwaraFrameSerializer().deserialize(json.dumps(inbound))
        )
        self.assertIsInstance(input_frame, InputTransportMessageFrame)
        assert isinstance(input_frame, InputTransportMessageFrame)
        self.assertEqual(input_frame.message, inbound)

        outbound = {"type": "state", "state": "listening"}
        wire = asyncio.run(
            SwaraFrameSerializer().serialize(
                OutputTransportMessageFrame(message=outbound)
            )
        )
        self.assertEqual(json.loads(wire), outbound)


if __name__ == "__main__":
    unittest.main(verbosity=2)
