from movieclaw_api.i18n.stored import render_value
from movieclaw_playback.text import Text


class PlaybackError(RuntimeError):
    """Keep the decision reference when an internal failure becomes an HTTP error."""

    def __init__(self, message: Text):
        self.message_key = message.get("message_key") if isinstance(message, dict) else None
        self.message_params = message.get("params") if isinstance(message, dict) else None
        super().__init__(render_value(message))
