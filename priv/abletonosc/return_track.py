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
# Listeners, so a return fader or the master fader moved in Live's UI reaches
# Seshat without waiting for the next refresh:
#
#   /live/return_track/start_listen/name    [index]   -> pushes [index, name]
#   /live/return_track/stop_listen/name     [index]
#   /live/return_track/start_listen/volume  [index]   -> pushes [index, value]
#   /live/return_track/stop_listen/volume   [index]
#   /live/master/start_listen/volume        []        -> pushes [value]
#   /live/master/stop_listen/volume         []
#
# Each pushes on the matching get/ address. The push shape is deliberately the
# bare pair rather than the ok/error envelope a query reply carries, so the two
# stay distinguishable by arity on the Elixir side; a push has no failure path to
# report anyway.
#
# start_listen/stop_listen are silent on a bad index, like the setters: nothing
# waits on one, and the caller has already read `get/count` to know what exists.
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
        self.osc_server.add_handler("/live/return_track/start_listen/name",
                                    self._start_listen_name)
        self.osc_server.add_handler("/live/return_track/stop_listen/name",
                                    self._stop_listen_name)
        self.osc_server.add_handler("/live/return_track/start_listen/volume",
                                    self._start_listen_volume)
        self.osc_server.add_handler("/live/return_track/stop_listen/volume",
                                    self._stop_listen_volume)
        self.osc_server.add_handler("/live/master/start_listen/volume",
                                    self._start_listen_master_volume)
        self.osc_server.add_handler("/live/master/stop_listen/volume",
                                    self._stop_listen_master_volume)

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
    # Return track listeners
    #--------------------------------------------------------------------------------
    def _start_listen_name(self, params: Tuple[Any] = ()) -> None:
        index, track, error = self._return_track(params, "start_listen/name")
        if error is not None:
            return None

        #--------------------------------------------------------------------------------
        # A return track is a LOM Track, so `name` is an ordinary listenable
        # property and the base class derives the right address on its own:
        # /live/return_track/get/name, sent as (index, name).
        #
        # The base class would re-listen on its own, but its removal step is
        # unsafe here — see _stop_listen_stored.
        #--------------------------------------------------------------------------------
        self._stop_listen_stored("name", (index,))
        self._start_listen(track, "name", (index,))

    def _stop_listen_name(self, params: Tuple[Any] = ()) -> None:
        index, track, error = self._return_track(params, "stop_listen/name")
        if error is not None:
            return None

        self._stop_listen_stored("name", (index,))

    def _start_listen_volume(self, params: Tuple[Any] = ()) -> None:
        index, track, error = self._return_track(params, "start_listen/volume")
        if error is not None:
            return None

        self._listen_to_volume(track.mixer_device.volume,
                               "/live/return_track/get/volume",
                               reply_prefix=(index,),
                               listener_params=(index,))

    def _stop_listen_volume(self, params: Tuple[Any] = ()) -> None:
        index, track, error = self._return_track(params, "stop_listen/volume")
        if error is not None:
            return None

        self._stop_listen_stored("value", (index,))

    #--------------------------------------------------------------------------------
    # Master track
    #--------------------------------------------------------------------------------
    def _start_listen_master_volume(self, params: Tuple[Any] = ()) -> None:
        #--------------------------------------------------------------------------------
        # The master needs no index, but its listener still needs a key that can't
        # collide with a return track's — hence the "master" sentinel. It never
        # reaches the wire: the push carries the bare value.
        #--------------------------------------------------------------------------------
        self._listen_to_volume(self.song.master_track.mixer_device.volume,
                               "/live/master/get/volume",
                               reply_prefix=(),
                               listener_params=("master",))

    def _stop_listen_master_volume(self, params: Tuple[Any] = ()) -> None:
        self._stop_listen_stored("value", ("master",))

    def _stop_listen_stored(self, prop, listener_params) -> None:
        """
        Stop a listener, removing it from the object it was actually registered on.

        The base `_stop_listen` removes the callback from the `target` it is
        handed, but our listeners are keyed by *index* while being bound to an
        *object* — and a return track's index is not stable. Delete return 0 of
        [A, B, C] and index 0 now means B, so re-subscribing hands the base class
        B while the stored callback belongs to A. `B.remove_name_listener` then
        raises, the base swallows it as "likely benign", and the dict entry is
        dropped regardless — leaving A's listener alive in Live forever, still
        pushing under index 0. B ends up with two listeners and a later rename
        writes B's name into the mirror under an index that belongs to C.

        The base class already stores the true object in `listener_objects` (its
        own `_clear_listeners` reads it), so passing that back is all it takes.
        Silent when nothing is registered: nothing waits on a stop_listen, and a
        stop for an index never listened to is not an error.
        """
        listener_key = (prop, tuple(listener_params))
        if listener_key in self.listener_functions:
            self._stop_listen(self.listener_objects[listener_key], prop, listener_params)

    def _listen_to_volume(self, parameter, address, reply_prefix, listener_params) -> None:
        """
        Listen to a mixer volume fader, pushing its value on `address`.

        Hand-rolled rather than delegated to the base `_start_listen`, because the
        listenable object here is not the track: it is `mixer_device.volume`, a
        DeviceParameter whose change notification is `add_value_listener`. The base
        class would name the property "value" and derive
        /live/return_track/get/value — an address nothing serves or expects.

        Everything else the base class does is bookkeeping over
        `listener_functions` / `listener_objects`, keyed by (prop, params). So
        registering under ("value", listener_params) with the DeviceParameter as the
        object keeps `_stop_listen` (remove_value_listener) and `_clear_listeners`
        (cleanup on reload) working unchanged. Re-listening stays idempotent via
        `_stop_listen_stored`, which is what makes it safe when the same index has
        come to mean a different return track. The immediate first push matches
        base behaviour too.
        """
        def value_changed_callback():
            self.osc_server.send(address, (*reply_prefix, parameter.value))

        listener_key = ("value", tuple(listener_params))
        self._stop_listen_stored("value", listener_params)

        self.logger.info("Return track: adding volume listener %s" % str(listener_params))
        parameter.add_value_listener(value_changed_callback)
        self.listener_functions[listener_key] = value_changed_callback
        self.listener_objects[listener_key] = parameter

        value_changed_callback()

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
