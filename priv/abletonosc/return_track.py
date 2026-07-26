from typing import Any, Tuple

from .handler import AbletonOSCHandler

#--------------------------------------------------------------------------------
# Return Track & Master API — a Seshat extension to AbletonOSC.
#
# Upstream AbletonOSC reaches regular tracks only: every /live/track/* handler
# resolves its index through `song.tracks`, which holds audio and MIDI tracks
# and nothing else. Return tracks live in `song.return_tracks` and the master in
# `song.master_track`, so upstream can create and delete a return track but can
# neither name one nor touch its level — and the master fader is unreachable
# entirely.
#
# Seshat needs the names in particular: sends are addressed by index (send 0 =
# send A = return track 0), and the only way to turn "the reverb send" into an
# index is to read the return tracks' names in order.
#
#   /live/return_track/get/count    []                -> [count]
#   /live/return_track/get/name     [index]           -> [index, "ok", name]
#                                                     -> [index, "error", message]
#   /live/return_track/set/name     [index, name]     -> (no reply)
#   /live/return_track/get/volume   [index]           -> [index, "ok", volume]
#                                                     -> [index, "error", message]
#   /live/return_track/set/volume   [index, value]    -> (no reply)
#   /live/master/get/volume         []                -> [volume]
#   /live/master/set/volume         [value]           -> (no reply)
#
# Getters follow browser.py's rule: always reply on the address they were called
# on, including on every error path. Upstream's convention — raise inside the
# callback and send nothing — is the wrong one for an optional extension. A
# silent bad index is indistinguishable from "the user never ran
# `mix abletonosc.install`", and it costs the caller a full guard timeout to
# learn nothing. Replying makes the two cases immediately separable: an error
# envelope is a bad index, and silence means the extension isn't loaded.
#
# `get/count` and `/live/master/get/volume` take no index and so have no failure
# path to report; they reply with the bare value.
#
# Setters stay silent. Each one is guarded by its matching getter immediately
# before it on the Elixir side, so the bad-index case is already reported by the
# time a setter is sent, and nothing ever waits on a setter's reply.
#
# Volume is 0.0-1.0 on Live's fader scale, read and written through
# `mixer_device.volume.value` — the same reason upstream's TrackHandler
# special-cases volume and panning.
#
# Installed by `mix abletonosc.install` from the Seshat repo.
#--------------------------------------------------------------------------------


class ReturnTrackHandler(AbletonOSCHandler):
    def __init__(self, manager):
        super().__init__(manager)
        self.class_identifier = "return_track"

    def init_api(self):
        self.osc_server.add_handler("/live/return_track/get/count", self._get_count)
        self.osc_server.add_handler("/live/return_track/get/name", self._get_name)
        self.osc_server.add_handler("/live/return_track/set/name", self._set_name)
        self.osc_server.add_handler("/live/return_track/get/volume", self._get_volume)
        self.osc_server.add_handler("/live/return_track/set/volume", self._set_volume)
        self.osc_server.add_handler("/live/master/get/volume", self._get_master_volume)
        self.osc_server.add_handler("/live/master/set/volume", self._set_master_volume)

    #--------------------------------------------------------------------------------
    # Return tracks
    #--------------------------------------------------------------------------------
    def _get_count(self, params: Tuple[Any] = ()) -> Tuple:
        return (len(self.song.return_tracks),)

    def _get_name(self, params: Tuple[Any] = ()) -> Tuple:
        index, track, error = self._return_track(params, "get/name")
        if error is not None:
            return (index, "error", error)

        return (index, "ok", track.name)

    def _set_name(self, params: Tuple[Any] = ()) -> None:
        index, track, error = self._return_track(params, "set/name")
        if error is not None:
            return None

        if len(params) < 2:
            self.logger.error("Return track: set/name requires [index, name]")
            return None

        track.name = str(params[1])

    def _get_volume(self, params: Tuple[Any] = ()) -> Tuple:
        index, track, error = self._return_track(params, "get/volume")
        if error is not None:
            return (index, "error", error)

        return (index, "ok", track.mixer_device.volume.value)

    def _set_volume(self, params: Tuple[Any] = ()) -> None:
        index, track, error = self._return_track(params, "set/volume")
        if error is not None:
            return None

        try:
            value = float(params[1])
        except (IndexError, TypeError, ValueError):
            self.logger.error("Return track: set/volume requires [index, value]")
            return None

        track.mixer_device.volume.value = value

    #--------------------------------------------------------------------------------
    # Master track
    #--------------------------------------------------------------------------------
    def _get_master_volume(self, params: Tuple[Any] = ()) -> Tuple:
        return (self.song.master_track.mixer_device.volume.value,)

    def _set_master_volume(self, params: Tuple[Any] = ()) -> None:
        try:
            value = float(params[0])
        except (IndexError, TypeError, ValueError):
            self.logger.error("Master: set/volume requires [value]")
            return None

        self.song.master_track.mixer_device.volume.value = value

    #--------------------------------------------------------------------------------
    # Lookup
    #--------------------------------------------------------------------------------
    def _return_track(self, params: Tuple[Any], operation: str):
        """
        Resolve params[0] to a return track, bounds-checked.

        Returns (index, track, None) on success and (index, None, message) on
        failure. The index is echoed back verbatim even when it is out of range,
        so the caller's reply still correlates with the query that asked for it.
        """
        try:
            index = int(params[0])
        except (IndexError, TypeError, ValueError):
            message = "%s requires a return track index as its first argument" % operation
            self.logger.error("Return track: %s" % message)
            return (-1, None, message)

        return_tracks = self.song.return_tracks
        if index < 0 or index >= len(return_tracks):
            message = "Return track %d does not exist — this set has %d return track(s)" % (
                index, len(return_tracks))
            self.logger.error("Return track: %s (%s)" % (message, operation))
            return (index, None, message)

        return (index, return_tracks[index], None)
