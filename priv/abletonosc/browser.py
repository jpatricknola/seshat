from typing import Any, Optional, Tuple

import Live

from .handler import AbletonOSCHandler

#--------------------------------------------------------------------------------
# Browser API — a Seshat extension to AbletonOSC.
#
# Upstream AbletonOSC exposes no browser API at all, so this handler adds the
# two endpoints Seshat needs in order to load instruments and effects:
#
#   /live/browser/get/items   [category, filter, max_results]
#     -> [category, filter, "ok", returned, total, name, uri, name, uri, ...]
#     -> [category, filter, "error", message]
#
#   /live/browser/load_item   [track_index, uri]
#     -> [track_index, uri, "ok", loaded_device_name]
#     -> [track_index, uri, "error", message]
#
# Both endpoints always reply on the address they were called on, including on
# every error path — OSC is fire-and-forget UDP, so a client waiting for a
# matching reply would otherwise hang until its timeout.
#
# Installed by `mix abletonosc.install` from the Seshat repo.
#--------------------------------------------------------------------------------

CATEGORIES = (
    "instruments",
    "sounds",
    "drums",
    "audio_effects",
    "midi_effects",
    "plugins",
    "samples",
    "user_library",
)

#--------------------------------------------------------------------------------
# The browser walk runs on Live's UI thread, which blocks the UI while it runs.
# These caps bound the worst case on very large samples/packs trees.
#--------------------------------------------------------------------------------
MAX_SCAN_NODES = 20000
MAX_DEPTH = 6

DEFAULT_MAX_RESULTS = 25
MAX_RESULTS_LIMIT = 100


class BrowserHandler(AbletonOSCHandler):
    def __init__(self, manager):
        super().__init__(manager)
        self.class_identifier = "browser"

    def init_api(self):
        #--------------------------------------------------------------------------------
        # init_api() is called from AbletonOSCHandler.__init__, so it must not
        # depend on anything assigned in our own __init__ body. The cache is
        # created here and survives clear_api()/init_api() reload cycles only
        # insofar as the handler object does — a fresh handler re-indexes.
        #--------------------------------------------------------------------------------
        if not hasattr(self, "_index_cache"):
            # category name -> list of (name, uri, BrowserItem)
            self._index_cache = {}

        self.osc_server.add_handler("/live/browser/get/items", self._get_items)
        self.osc_server.add_handler("/live/browser/load_item", self._load_item)

    #--------------------------------------------------------------------------------
    # Endpoints
    #--------------------------------------------------------------------------------
    def _get_items(self, params: Tuple[Any] = ()) -> Tuple:
        category = str(params[0]) if len(params) > 0 else ""
        name_filter = str(params[1]) if len(params) > 1 else ""
        max_results = _clamp_max_results(params[2] if len(params) > 2 else None)

        if category not in CATEGORIES:
            return (category, name_filter, "error",
                    "Unknown category '%s'. Valid categories: %s"
                    % (category, ", ".join(CATEGORIES)))

        try:
            index = self._index(category)
        except Exception as e:
            self.logger.error("Browser: failed to index category %s: %s" % (category, e))
            return (category, name_filter, "error",
                    "Could not index category '%s': %s" % (category, e))

        needle = name_filter.lower()
        matches = [(name, uri) for (name, uri, _item) in index if needle in name.lower()]
        returned = matches[:max_results]

        flat = []
        for name, uri in returned:
            flat.append(name)
            flat.append(uri)

        return (category, name_filter, "ok", len(returned), len(matches), *flat)

    def _load_item(self, params: Tuple[Any] = ()) -> Tuple:
        try:
            track_index = int(params[0])
        except (IndexError, TypeError, ValueError):
            return (-1, "", "error", "load_item requires [track_index, uri]")

        uri = str(params[1]) if len(params) > 1 else ""
        if not uri:
            return (track_index, uri, "error", "Missing browser item uri")

        tracks = list(self.song.tracks)
        if track_index < 0 or track_index >= len(tracks):
            return (track_index, uri, "error",
                    "Track index %d out of range — the set has %d track(s)"
                    % (track_index, len(tracks)))
        track = tracks[track_index]

        try:
            item = self._find_item(uri)
        except Exception as e:
            self.logger.error("Browser: failed to search for uri %s: %s" % (uri, e))
            return (track_index, uri, "error", "Could not search the browser: %s" % e)

        if item is None:
            return (track_index, uri, "error",
                    "No browser item found with uri '%s' — "
                    "query /live/browser/get/items to get a valid uri" % uri)

        try:
            #--------------------------------------------------------------------------------
            # browser.load_item() always loads onto the selected track, so the
            # selection and the load happen together here rather than being
            # split across two OSC messages (which would race).
            #--------------------------------------------------------------------------------
            self.song.view.selected_track = track
            Live.Application.get_application().browser.load_item(item)
        except Exception as e:
            self.logger.error("Browser: failed to load %s: %s" % (uri, e))
            return (track_index, uri, "error", "Could not load '%s': %s" % (item.name, e))

        return (track_index, uri, "ok", self._loaded_device_name(track, item))

    #--------------------------------------------------------------------------------
    # Indexing
    #--------------------------------------------------------------------------------
    def _index(self, category: str):
        """
        Return a cached list of (name, uri, BrowserItem) for every loadable item
        under `category`. The BrowserItem is kept so that a later load needs no
        second walk.
        """
        if category in self._index_cache:
            return self._index_cache[category]

        browser = Live.Application.get_application().browser
        root = getattr(browser, category)

        items = []
        seen_uris = set()
        scanned = 0
        stack = [(child, 1) for child in reversed(_children_of(root))]

        while stack:
            item, depth = stack.pop()

            scanned += 1
            if scanned > MAX_SCAN_NODES:
                self.logger.warning(
                    "Browser: hit scan cap of %d nodes indexing '%s' — "
                    "index may be incomplete" % (MAX_SCAN_NODES, category))
                break

            try:
                if item.is_loadable:
                    uri = item.uri
                    if uri and uri not in seen_uris:
                        seen_uris.add(uri)
                        items.append((item.name, uri, item))

                if depth < MAX_DEPTH:
                    for child in reversed(_children_of(item)):
                        stack.append((child, depth + 1))
            except RuntimeError:
                #--------------------------------------------------------------------------------
                # Live raises RuntimeError when a browser node goes stale
                # mid-walk (e.g. a disconnected drive). Skip it.
                #--------------------------------------------------------------------------------
                continue

        self.logger.info("Browser: indexed %d loadable item(s) in '%s' (%d nodes scanned)"
                         % (len(items), category, scanned))
        self._index_cache[category] = items
        return items

    def _find_item(self, uri: str) -> Optional[Any]:
        #--------------------------------------------------------------------------------
        # Already-indexed categories first: the common path is a load straight
        # after a get/items call on the same category.
        #--------------------------------------------------------------------------------
        for category in list(self._index_cache.keys()):
            for (_name, item_uri, item) in self._index_cache[category]:
                if item_uri == uri:
                    return item

        for category in CATEGORIES:
            if category in self._index_cache:
                continue
            for (_name, item_uri, item) in self._index(category):
                if item_uri == uri:
                    return item

        return None

    def _loaded_device_name(self, track, item) -> str:
        """
        Read back the track's device list so the reply positively confirms what
        landed, rather than echoing what we asked for.
        """
        try:
            names = [device.name for device in track.devices]
        except Exception:
            return item.name

        if not names:
            #--------------------------------------------------------------------------------
            # Some VST/AU plugins instantiate asynchronously and aren't on the
            # track yet. Fall back to the browser item's own name.
            #--------------------------------------------------------------------------------
            return item.name

        #--------------------------------------------------------------------------------
        # load_item() does not always append at the end — an instrument lands
        # before any existing audio effects — so prefer a name match.
        #--------------------------------------------------------------------------------
        for name in names:
            if name == item.name:
                return name

        return names[-1]


def _children_of(item) -> list:
    try:
        return list(item.children)
    except (AttributeError, RuntimeError):
        return []


def _clamp_max_results(value) -> int:
    try:
        max_results = int(value)
    except (TypeError, ValueError):
        return DEFAULT_MAX_RESULTS

    return max(1, min(MAX_RESULTS_LIMIT, max_results))
