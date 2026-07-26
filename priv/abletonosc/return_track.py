from typing import Any, Optional, Tuple

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
#   /live/return_track/get/name     [index]           -> [index, name]
#   /live/return_track/set/name     [index, name]     -> (no reply)
#   /live/return_track/get/volume   [index]           -> [index, volume]
#   /live/return_track/set/volume   [index, volume]   -> (no reply)
#   /live/master/get/volume         []                -> [volume]
#   /live/master/set/volume         [volume]          -> (no reply)
#
# Unlike browser.py, these follow upstream's convention rather than replying with
# an ok/error envelope: an out-of-range index is logged and simply not replied
# to, exactly as an IndexError inside an upstream callback would be. Every Elixir
# caller validates the index with get/count or a guard get first, so the mixed
# reply shape would buy nothing.
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

    def _get_name(self, params: Tuple[Any] = ()) -> Optional[Tuple]:
        index, track = self._return_track(params, "get/name")
        if track is None:
            return None

        return (index, track.name)

    def _set_name(self, params: Tuple[Any] = ()) -> None:
        index, track = self._return_track(params, "set/name")
        if track is None:
            return None

        if len(params) < 2:
            self.logger.error("Return track: set/name requires [index, name]")
            return None

        track.name = str(params[1])

    def _get_volume(self, params: Tuple[Any] = ()) -> Optional[Tuple]:
        index, track = self._return_track(params, "get/volume")
        if track is None:
            return None

        return (index, track.mixer_device.volume.value)

    def _set_volume(self, params: Tuple[Any] = ()) -> None:
        index, track = self._return_track(params, "set/volume")
        if track is None:
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

        Returns (index, track), or (index, None) when the index is missing or out
        of range — in which case the caller replies with nothing at all, the same
        silence an upstream IndexError produces.
        """
        try:
            index = int(params[0])
        except (IndexError, TypeError, ValueError):
            self.logger.error("Return track: %s requires a return track index" % operation)
            return (-1, None)

        return_tracks = self.song.return_tracks
        if index < 0 or index >= len(return_tracks):
            self.logger.error("Return track: %s index %d out of range — the set has %d return "
                              "track(s)" % (operation, index, len(return_tracks)))
            return (index, None)

        return (index, return_tracks[index])
