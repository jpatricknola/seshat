from typing import Any, Tuple

from .handler import AbletonOSCHandler

#--------------------------------------------------------------------------------
# Song Structure API — a Seshat extension to AbletonOSC.
#
# Upstream AbletonOSC only exposes listeners for *scalar* Song properties: its
# SongHandler loops over a hardcoded list (tempo, root_note, is_playing, ...) and
# registers /live/song/start_listen/<prop> for each. `tracks` and `return_tracks`
# are not in that list — they are lists of LOM objects, and the generic
# `_start_listen` would try to OSC-encode a Track. So nothing upstream fires when
# a track is added, deleted, duplicated or reordered in Live's UI, and
# Seshat.Session.State's mirror silently drifts (it reported 7 tracks when 3
# existed).
#
# The base class already supports this: `_start_listen` takes an optional
# `getter`, so the listener can push a value derived from the target rather than
# the raw property. A tuple of names is all Seshat needs — it compares the pushed
# names against its mirror and re-reads everything only when they differ, so this
# handler stays a change *signal* rather than a second source of truth.
#
#   /live/song/start_listen/tracks         []  -> pushes /live/song/get/tracks
#   /live/song/stop_listen/tracks          []
#   /live/song/start_listen/return_tracks  []  -> pushes /live/song/get/return_tracks
#   /live/song/stop_listen/return_tracks   []
#
# The pushes carry the names in order and nothing else:
#
#   /live/song/get/tracks         [name0, name1, ...]
#   /live/song/get/return_tracks  [name0, name1, ...]
#
# Neither push address is registered as a handler — they are push-only, sent by
# the listener callback and never queried. Upstream registers no handler on
# either address (it has /live/song/get/track_names, a different address), so
# there is no collision.
#
# start_listen/stop_listen reply only by pushing, never with an error envelope:
# unlike the getters in browser.py and return_track.py, nothing on the Elixir
# side waits on them, and they take no index that could be out of range.
#
# Installed by `mix abletonosc.install` from the Seshat repo.
#--------------------------------------------------------------------------------


class SongStructureHandler(AbletonOSCHandler):
    def __init__(self, manager):
        super().__init__(manager)
        self.class_identifier = "song"

    def init_api(self):
        self.osc_server.add_handler("/live/song/start_listen/tracks",
                                    self._start_listen_tracks)
        self.osc_server.add_handler("/live/song/stop_listen/tracks",
                                    self._stop_listen_tracks)
        self.osc_server.add_handler("/live/song/start_listen/return_tracks",
                                    self._start_listen_return_tracks)
        self.osc_server.add_handler("/live/song/stop_listen/return_tracks",
                                    self._stop_listen_return_tracks)

    #--------------------------------------------------------------------------------
    # Tracks
    #--------------------------------------------------------------------------------
    def _start_listen_tracks(self, params: Tuple[Any] = ()) -> None:
        self._start_listen(self.song, "tracks", (), self._track_names)

    def _stop_listen_tracks(self, params: Tuple[Any] = ()) -> None:
        self._stop_listen(self.song, "tracks", ())

    def _track_names(self, params: Tuple[Any] = ()) -> Tuple:
        return tuple(track.name for track in self.song.tracks)

    #--------------------------------------------------------------------------------
    # Return tracks
    #--------------------------------------------------------------------------------
    def _start_listen_return_tracks(self, params: Tuple[Any] = ()) -> None:
        self._start_listen(self.song, "return_tracks", (), self._return_track_names)

    def _stop_listen_return_tracks(self, params: Tuple[Any] = ()) -> None:
        self._stop_listen(self.song, "return_tracks", ())

    def _return_track_names(self, params: Tuple[Any] = ()) -> Tuple:
        return tuple(track.name for track in self.song.return_tracks)
