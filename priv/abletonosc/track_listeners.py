from typing import Any, Callable, List, Tuple

from .handler import AbletonOSCHandler

#--------------------------------------------------------------------------------
# Track Listener API — a Seshat override of upstream AbletonOSC.
#
# Unlike the other files in this directory, this one registers no new addresses.
# It *replaces* upstream's handlers for the five track listeners
# Seshat.Session.State subscribes to, because upstream's unbind the listener from
# the wrong object once a track index has been reused.
#
#   /live/track/start_listen/name      [index | "*"]  -> pushes [index, name]
#   /live/track/stop_listen/name       [index | "*"]
#   /live/track/start_listen/mute      [index | "*"]  -> pushes [index, 0|1]
#   /live/track/stop_listen/mute       [index | "*"]
#   /live/track/start_listen/solo      [index | "*"]  -> pushes [index, 0|1]
#   /live/track/stop_listen/solo       [index | "*"]
#   /live/track/start_listen/volume    [index | "*"]  -> pushes [index, value]
#   /live/track/stop_listen/volume     [index | "*"]
#   /live/track/start_listen/panning   [index | "*"]  -> pushes [index, value]
#   /live/track/stop_listen/panning    [index | "*"]
#
# Same addresses, same argument shapes, same pushes as upstream — nothing on the
# Elixir side can tell the difference, and that is the point. `OSCServer.add_handler`
# is a plain dict assignment (`self._callbacks[address] = handler`), so the last
# registration for an address wins, and manager.py instantiates TrackHandler
# before the Seshat handlers appended after MidiMapHandler. If that ordering ever
# changes upstream, this file silently stops taking effect.
#
# THE BUG THIS EXISTS TO FIX
#
# A track listener is keyed by index but bound to an object, and deleting a track
# renumbers every track after it. Upstream's stop step unbinds from whatever
# target it resolves *now*:
#
#   * for name/mute/solo, the base class's `_stop_listen` calls
#     `remove_<prop>_listener` on the target it is handed, and `_start_listen`
#     hands it the freshly resolved track;
#   * for volume/panning, `TrackHandler._stop_mixer_listen` re-derives
#     `target.mixer_device.<prop>` the same way.
#
# So with tracks [A, B, C] and listeners on indices 0, 1, 2: delete A, and
# Session.State refreshes and re-subscribes indices 0 and 1. Index 0 now means B,
# so upstream tries to unbind A's callback from B. The base class swallows the
# failure as "likely benign" and drops the bookkeeping entry anyway, leaving B
# listening under BOTH index 0 (new, correct) and index 1 (old, stale). Rename B
# and it pushes twice — and the [1, name] push writes B's name onto C in the
# mirror. Exactly the silent drift Session.State's listeners exist to prevent.
#
# The fix is to unbind the object the callback was actually registered on, which
# the base class already records in `listener_objects` — see `_stop_listen_stored`
# below, and the same helper in return_track.py, where returns have the identical
# problem.
#
# Upstream's mixer listeners have a second bug this inherits the fix for: they
# populate `listener_functions` but never `listener_objects`, so the base
# `_clear_listeners` would raise KeyError on reload as soon as one is active.
# Registering both, as this file does, is what makes reload cleanup work.
#
# Only the five properties Session.State listens to are overridden. Every other
# track listener upstream serves keeps upstream's behaviour, bug included —
# `vendored_addresses_test` fails if Session.State's list ever grows past the
# addresses registered here, since the address would keep answering and give no
# other sign that it had fallen back to the broken path.
#
# Installed by `mix abletonosc.install` from the Seshat repo.
#--------------------------------------------------------------------------------

class TrackListenerHandler(AbletonOSCHandler):
    def __init__(self, manager):
        super().__init__(manager)
        self.class_identifier = "track"

    def init_api(self):
        #--------------------------------------------------------------------------------
        # Written out one address per line rather than looped over a property list:
        # vendored_addresses_test greps this file for "/live/..." literals and
        # checks each against what Session.State sends, and an address built with
        # a %s is invisible to that tripwire. Same rule as the Elixir side.
        #
        # Plain properties are listenable directly on the LOM Track object
        # (`add_name_listener` and friends), so the base class can drive them.
        #--------------------------------------------------------------------------------
        self.osc_server.add_handler("/live/track/start_listen/name",
                                    self._callback(self._start_listen_plain, "name"))
        self.osc_server.add_handler("/live/track/stop_listen/name",
                                    self._callback(self._stop_listen_plain, "name"))
        self.osc_server.add_handler("/live/track/start_listen/mute",
                                    self._callback(self._start_listen_plain, "mute"))
        self.osc_server.add_handler("/live/track/stop_listen/mute",
                                    self._callback(self._stop_listen_plain, "mute"))
        self.osc_server.add_handler("/live/track/start_listen/solo",
                                    self._callback(self._start_listen_plain, "solo"))
        self.osc_server.add_handler("/live/track/stop_listen/solo",
                                    self._callback(self._stop_listen_plain, "solo"))

        #--------------------------------------------------------------------------------
        # Mixer properties live on `track.mixer_device.<prop>`, a DeviceParameter
        # whose change notification is `add_value_listener` — the reason upstream
        # special-cases these two, and the reason they can't go through the base
        # class's `_start_listen`.
        #--------------------------------------------------------------------------------
        self.osc_server.add_handler("/live/track/start_listen/volume",
                                    self._callback(self._start_listen_mixer, "volume"))
        self.osc_server.add_handler("/live/track/stop_listen/volume",
                                    self._callback(self._stop_listen_mixer, "volume"))
        self.osc_server.add_handler("/live/track/start_listen/panning",
                                    self._callback(self._start_listen_mixer, "panning"))
        self.osc_server.add_handler("/live/track/stop_listen/panning",
                                    self._callback(self._stop_listen_mixer, "panning"))

    #--------------------------------------------------------------------------------
    # Plain Track properties
    #--------------------------------------------------------------------------------
    def _start_listen_plain(self, prop: str, index: int) -> None:
        #--------------------------------------------------------------------------------
        # The base class derives the address and the push shape correctly
        # (/live/track/get/<prop>, sent as (index, value)) — only its re-listen
        # teardown is unsafe, so that is done here first and the key is gone by the
        # time `_start_listen` checks for it.
        #--------------------------------------------------------------------------------
        self._stop_listen_stored(prop, (index,))
        self._start_listen(self.song.tracks[index], prop, (index,))

    def _stop_listen_plain(self, prop: str, index: int) -> None:
        self._stop_listen_stored(prop, (index,))

    #--------------------------------------------------------------------------------
    # Mixer properties
    #--------------------------------------------------------------------------------
    def _start_listen_mixer(self, prop: str, index: int) -> None:
        parameter = getattr(self.song.tracks[index].mixer_device, prop)

        #--------------------------------------------------------------------------------
        # The push address upstream would derive, and the one Session.State matches
        # on: /live/track/get/volume and /live/track/get/panning. Both are upstream
        # getters, registered by TrackHandler and left alone by this file.
        #--------------------------------------------------------------------------------
        address = "/live/track/get/%s" % prop

        def value_changed_callback():
            self.osc_server.send(address, (index, parameter.value))

        self._stop_listen_mixer(prop, index)

        self.logger.info("Track listeners: adding %s listener for track %d" % (prop, index))
        parameter.add_value_listener(value_changed_callback)

        listener_key = self._mixer_key(prop, index)
        self.listener_functions[listener_key] = value_changed_callback
        self.listener_objects[listener_key] = parameter

        #--------------------------------------------------------------------------------
        # Immediately send the current value, matching upstream and the base class.
        #--------------------------------------------------------------------------------
        value_changed_callback()

    def _stop_listen_mixer(self, prop: str, index: int) -> None:
        self._stop_listen_stored(*self._mixer_key(prop, index))

    @staticmethod
    def _mixer_key(prop: str, index: int) -> Tuple[str, Tuple]:
        #--------------------------------------------------------------------------------
        # A DeviceParameter's only remove function is `remove_value_listener`, so the
        # base class's teardown requires the property be named "value" — which would
        # make volume and panning on the same track collide. Carrying the real
        # property name in the params tuple keeps them apart. It never reaches the
        # wire: the push above is hand-rolled and sends only (index, value).
        #--------------------------------------------------------------------------------
        return ("value", (index, prop))

    #--------------------------------------------------------------------------------
    # Shared
    #--------------------------------------------------------------------------------
    def _stop_listen_stored(self, prop: str, listener_params: Tuple) -> None:
        """
        Stop a listener, removing it from the object it was actually registered on.

        The whole point of this file — see the header. Kept in step with the copy in
        return_track.py; the two handlers are installed independently, so neither can
        import from the other.
        """
        listener_key = (prop, tuple(listener_params))
        if listener_key in self.listener_functions:
            self._stop_listen(self.listener_objects[listener_key], prop, listener_params)

    def _callback(self, action: Callable, prop: str) -> Callable:
        def track_listener_callback(params: Tuple[Any] = ()) -> None:
            for index in self._track_indices(params, prop):
                action(prop, index)

        return track_listener_callback

    def _track_indices(self, params: Tuple[Any], operation: str) -> List[int]:
        """
        Resolve params[0] to track indices, supporting upstream's "*" wildcard.

        Returns [] on anything unusable. Silence is the right reply for a listener
        subscription: nothing on the Elixir side waits on one, and the caller has
        already read `/live/song/get/num_tracks` to know what exists — the same rule
        the vendored setters follow.
        """
        try:
            selector = params[0]
        except IndexError:
            self.logger.error("Track listeners: %s requires a track index or \"*\"" % operation)
            return []

        track_count = len(self.song.tracks)
        if selector == "*":
            return list(range(track_count))

        try:
            index = int(selector)
        except (TypeError, ValueError):
            self.logger.error("Track listeners: %s got a non-numeric track index %s" % (
                operation, str(selector)))
            return []

        if index < 0 or index >= track_count:
            self.logger.error("Track listeners: track %d does not exist — this set has %d "
                              "track(s) (%s)" % (index, track_count, operation))
            return []

        return [index]
