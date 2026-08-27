// seshat-ax — Seshat's macOS Accessibility helper.
//
// Seshat controls Ableton Live through the Live Object Model, carried over OSC.
// Live's application-wide audio *device* preference is not in the LOM at all
// (checked against Live 12.4.3's shipped Python; see
// docs/evaluating/ui-scripting-options.md), so it is reachable only through the
// macOS Accessibility API — which the BEAM cannot call. This program is that
// call, and nothing else.
//
// It is deliberately NOT a generic UI remote. There is no "press this element",
// no tree dump, no keystroke, no coordinate click. The whole protocol is four
// commands:
//
//   seshat-ax version
//   seshat-ax permission [--prompt]
//   seshat-ax list-outputs
//   seshat-ax set-output --device "<exact display name>"
//
// Every command prints exactly one JSON document on stdout and nothing else —
// no human log text is mixed into the protocol, because `Seshat.AX.Client`
// parses the whole of stdout as one document. Success is
//
//   {"ok":true, ...,"protocol_version":1}
//
// and failure is one shape with a non-zero exit status:
//
//   {"ok":false,"code":"permission_required","message":"…","protocol_version":1}
//
// Codes: permission_required, live_not_running, settings_unavailable,
// device_not_found, ax_failure, timeout. `device_not_found` also carries the
// names that *are* available, so the model can recover in the same turn rather
// than guessing again.
//
// The selector path is bounded and semantic — the one measured in the
// 2026-08-03 spike. Live is found by bundle identifier (the bundle is named
// `Live`, not `Ableton Live`), activated (Live reports zero AX windows while
// inactive), and its Settings window, `audio` group, `Audio Output Device`
// popup and `ChooserPopUp` menu are all located by identifier, description or
// role. No step falls back to sibling order or coordinates. Every UI change the
// helper makes, it undoes: a chooser it opened is dismissed, a Settings page it
// switched is switched back, a Settings window it opened is closed, and the
// application that was frontmost when it started is brought back.
//
// One monotonic deadline (kActionDeadline) bounds the whole action, so a hung
// AX call cannot outlive the Elixir side's own Port deadline.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// Bumped whenever the JSON protocol changes shape. `Seshat.AX.Client` refuses a
// response carrying any other value and names `mix ax.install`, so an installed
// binary left behind by an older checkout fails loudly instead of subtly.
static const int kProtocolVersion = 1;

// The helper's own budget. The Elixir side allows 5,000ms around this, so a
// helper that honours its deadline always beats the Port timeout — the caller
// gets a structured `timeout` rather than a killed process.
static const NSTimeInterval kActionDeadline = 3.5;

// Per-AX-message timeout. Live answers in microseconds when healthy; a second
// is already pathological, and the overall deadline is the real bound.
static const float kMessagingTimeout = 1.0f;

// Targeted polling for the handful of UI transitions (activation, Settings
// appearing, the chooser opening, the popup's value settling). Every measured
// transition finished well inside one second, which is why V1 does not stand up
// an AXObserver runloop for them.
static const NSTimeInterval kPollInterval = 0.05;

// Activation gets its own sub-budget rather than the whole deadline. Live is
// asked to come forward and then the helper *proceeds regardless*: the readiness
// signal that matters is Live reporting AX windows, and a run that spent its
// entire budget waiting on an activation flag has nothing left to do the work
// with (measured 2026-08-27 — a `while (!live.active)` wait consumed all 4s and
// the command returned `timeout` having pressed nothing).
static const NSTimeInterval kActivationBudget = 1.2;

// How long to wait for the Settings window after pressing the menu item, and how
// many times to press. See the retry comment in AudioOutputTransaction: Live
// drops the press outright often enough that a single attempt is not a design.
static const NSTimeInterval kSettingsOpenWait = 0.8;
static const NSInteger kSettingsOpenAttempts = 3;

// Putting the previous application back is *waited on*, not fired and forgotten.
// Measured 2026-08-27: an unwaited restore landed during the next run, which
// then found Live frontmost, skipped its own activation, and left the run after
// that fighting a stale activation — a failure every third back-to-back call.
// Its own budget, outside the action deadline, so a failed action still cleans
// up; the sum stays inside the Elixir side's 5,000ms Port timeout.
static const NSTimeInterval kRestoreBudget = 0.6;

// Output is bounded on purpose: this protocol carries device names, never an AX
// tree. A machine with more audio devices than this has other problems.
static const NSUInteger kMaxDevices = 128;
static const NSUInteger kMaxNameLength = 256;

// Bounded search depths, measured against Live 12.4.3's Settings window. Each
// is a hard stop, so a Live release that reorganises the window makes the
// helper report `settings_unavailable` rather than walk thousands of elements.
static const NSInteger kSettingsSearchDepth = 8;
static const NSInteger kPopupSearchDepth = 3;
static const NSInteger kChooserSearchDepth = 3;
static const NSInteger kMenuSearchDepth = 8;

static NSString *const kCodePermissionRequired = @"permission_required";
static NSString *const kCodeLiveNotRunning = @"live_not_running";
static NSString *const kCodeSettingsUnavailable = @"settings_unavailable";
static NSString *const kCodeDeviceNotFound = @"device_not_found";
static NSString *const kCodeAXFailure = @"ax_failure";
static NSString *const kCodeTimeout = @"timeout";
static NSString *const kCodeUsage = @"usage";

static NSTimeInterval gStartedAt = 0;
static NSTimeInterval gDeadline = 0;

#pragma mark - Clock

// `systemUptime` is monotonic: it does not move when the wall clock does.
static NSTimeInterval Now(void) { return NSProcessInfo.processInfo.systemUptime; }

static BOOL PastDeadline(void) { return Now() >= gDeadline; }

// Pausing by running the runloop rather than `usleep`, because
// `NSRunningApplication`'s state arrives as a workspace notification: a
// command-line tool that only sleeps never processes it and reads a frozen
// `active` flag forever.
static void Pause(void) {
  [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:kPollInterval]];
}

static NSNumber *ElapsedMilliseconds(void) {
  return @((long long)((Now() - gStartedAt) * 1000.0));
}

#pragma mark - JSON protocol

static int StatusForCode(NSString *code) {
  if ([code isEqualToString:kCodePermissionRequired]) return 2;
  if ([code isEqualToString:kCodeLiveNotRunning]) return 3;
  if ([code isEqualToString:kCodeSettingsUnavailable]) return 4;
  if ([code isEqualToString:kCodeDeviceNotFound]) return 5;
  if ([code isEqualToString:kCodeTimeout]) return 7;
  if ([code isEqualToString:kCodeUsage]) return 8;
  return 6;
}

// The single exit point. Anything that reaches stdout goes through here, which
// is what makes "stdout holds one JSON document" a property of the program
// rather than a convention.
static int Emit(NSDictionary *payload) {
  NSMutableDictionary *document = [payload mutableCopy];
  document[@"protocol_version"] = @(kProtocolVersion);

  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:document
                                                 options:NSJSONWritingSortedKeys
                                                   error:&error];

  if (data == nil) {
    // A literal, not a second serialisation attempt: the caller parses stdout
    // unconditionally, so the protocol has to hold even here.
    fputs("{\"code\":\"ax_failure\",\"message\":\"Could not encode a JSON response.\","
          "\"ok\":false,\"protocol_version\":1}\n",
          stdout);
    fflush(stdout);
    return StatusForCode(kCodeAXFailure);
  }

  fwrite(data.bytes, 1, data.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);

  NSNumber *ok = document[@"ok"];
  return [ok boolValue] ? 0 : StatusForCode(document[@"code"]);
}

static NSDictionary *Failure(NSString *code, NSString *message) {
  return @{@"ok" : @NO, @"code" : code, @"message" : message};
}

#pragma mark - Accessibility reads

static CFTypeRef CopyAttribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = NULL;

  if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return NULL;

  return value;
}

// nil rather than a description for a non-string value: an Objective-C
// `-description` in the JSON would be exactly the kind of internal leakage the
// protocol exists to prevent.
static NSString *StringAttribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = CopyAttribute(element, name);
  if (value == NULL) return nil;

  NSString *string = nil;
  if (CFGetTypeID(value) == CFStringGetTypeID()) string = [(__bridge NSString *)value copy];
  CFRelease(value);

  if (string.length > kMaxNameLength) return [string substringToIndex:kMaxNameLength];

  return string;
}

static BOOL BooleanAttribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = CopyAttribute(element, name);
  if (value == NULL) return NO;

  BOOL result = NO;
  if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
    result = CFBooleanGetValue((CFBooleanRef)value);
  } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
    int number = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
    result = number != 0;
  }
  CFRelease(value);

  return result;
}

static NSArray *ElementsAttribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = CopyAttribute(element, name);
  if (value == NULL) return @[];

  NSArray *elements = @[];
  if (CFGetTypeID(value) == CFArrayGetTypeID()) elements = [(__bridge NSArray *)value copy];
  CFRelease(value);

  return elements;
}

static NSArray *ChildrenOf(AXUIElementRef element) {
  return ElementsAttribute(element, kAXChildrenAttribute);
}

static BOOL SupportsPress(AXUIElementRef element) {
  CFArrayRef actions = NULL;
  if (AXUIElementCopyActionNames(element, &actions) != kAXErrorSuccess || actions == NULL) {
    return NO;
  }

  BOOL pressable = CFArrayContainsValue(actions, CFRangeMake(0, CFArrayGetCount(actions)),
                                        kAXPressAction);
  CFRelease(actions);

  return pressable;
}

typedef BOOL (^AXMatch)(AXUIElementRef element);

// Depth-first, depth-bounded, first match wins. The bound is the whole safety
// story: no call in this file can enumerate Live's full tree.
static AXUIElementRef FindElement(AXUIElementRef root, NSInteger depth, AXMatch match) {
  if (match(root)) return (AXUIElementRef)CFRetain(root);
  if (depth <= 0 || PastDeadline()) return NULL;

  for (id child in ChildrenOf(root)) {
    AXUIElementRef found = FindElement((__bridge AXUIElementRef)child, depth - 1, match);
    if (found != NULL) return found;
  }

  return NULL;
}

static void CollectElements(AXUIElementRef root, NSInteger depth, AXMatch match,
                            NSMutableArray *into) {
  if (into.count >= kMaxDevices || PastDeadline()) return;

  if (match(root)) {
    [into addObject:(__bridge id)root];
    return;
  }

  if (depth <= 0) return;

  for (id child in ChildrenOf(root)) {
    CollectElements((__bridge AXUIElementRef)child, depth - 1, match, into);
  }
}

static AXMatch MatchIdentifier(NSString *identifier) {
  return ^BOOL(AXUIElementRef element) {
    return [StringAttribute(element, kAXIdentifierAttribute) isEqualToString:identifier];
  };
}

static AXMatch MatchRole(NSString *role) {
  return ^BOOL(AXUIElementRef element) {
    return [StringAttribute(element, kAXRoleAttribute) isEqualToString:role];
  };
}

#pragma mark - Live's Settings window

// Read the workspace's *current* frontmost application rather than the cached
// `active` flag on an `NSRunningApplication` captured earlier. That flag is
// updated by a workspace notification, and a short-lived tool that has only just
// started its runloop reads it stale — measured 2026-08-27, where a run
// immediately after another saw `active == YES` for a Live that had already been
// put back behind the editor, skipped activation, and then had its menu press
// silently ignored. Every third back-to-back run failed that way.
static BOOL LiveIsFrontmost(NSRunningApplication *live) {
  NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;

  return front != nil && front.processIdentifier == live.processIdentifier;
}

// Bring Live to the front and wait, within the activation budget, for macOS to
// agree that it is there. Unconditional: `activateWithOptions:` is a no-op for
// an application already in front, and trusting a cached flag instead is what
// made every third back-to-back run press a menu Live was not listening to.
// Bounded, and it proceeds regardless — a run that spent the whole action
// deadline waiting to be activated would have nothing left to act with.
static void ActivateAndWait(NSRunningApplication *live) {
  if (LiveIsFrontmost(live)) return;

  [live activateWithOptions:0];

  NSTimeInterval until = Now() + kActivationBudget;
  while (!LiveIsFrontmost(live) && Now() < until && !PastDeadline()) Pause();
}

static NSRunningApplication *RunningLive(void) {
  for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
    // By bundle identifier, never by name: the installed bundle and process are
    // called `Live`, so matching the product name "Ableton Live" reported that
    // Live was not running (measured 2026-08-03).
    if ([application.bundleIdentifier isEqualToString:@"com.ableton.live"]) return application;
  }

  return nil;
}

static AXUIElementRef SettingsWindow(AXUIElementRef application) {
  for (id window in ElementsAttribute(application, kAXWindowsAttribute)) {
    AXUIElementRef element = (__bridge AXUIElementRef)window;
    if ([StringAttribute(element, kAXTitleAttribute) isEqualToString:@"Settings"]) {
      return (AXUIElementRef)CFRetain(element);
    }
  }

  return NULL;
}

// Live's menu title carries a literal three-dot ellipsis on 12.4.3; the
// single-character form is accepted too so a typographic change is not a
// silent failure.
static AXError PressSettingsMenuItem(AXUIElementRef application) {
  CFTypeRef menuBar = CopyAttribute(application, kAXMenuBarAttribute);
  if (menuBar == NULL) return kAXErrorNoValue;

  AXUIElementRef item = FindElement((AXUIElementRef)menuBar, kMenuSearchDepth,
                                    ^BOOL(AXUIElementRef element) {
                                      NSString *title =
                                          StringAttribute(element, kAXTitleAttribute);
                                      return [title isEqualToString:@"Settings..."] ||
                                             [title isEqualToString:@"Settings…"];
                                    });

  AXError error = item != NULL ? AXUIElementPerformAction(item, kAXPressAction) : kAXErrorNoValue;
  if (item != NULL) CFRelease(item);
  CFRelease(menuBar);

  return error;
}

// Which page the Settings window is showing, so the helper can put it back. The
// pages are radio buttons; the selected one is the one with a truthy value.
static NSString *SelectedPageIdentifier(AXUIElementRef settings) {
  NSMutableArray *buttons = [NSMutableArray array];
  CollectElements(settings, kSettingsSearchDepth, MatchRole((__bridge NSString *)kAXRadioButtonRole),
                  buttons);

  for (id button in buttons) {
    AXUIElementRef element = (__bridge AXUIElementRef)button;
    if (BooleanAttribute(element, kAXValueAttribute)) {
      return StringAttribute(element, kAXIdentifierAttribute);
    }
  }

  return nil;
}

static BOOL PressIdentifier(AXUIElementRef root, NSString *identifier) {
  AXUIElementRef element = FindElement(root, kSettingsSearchDepth, MatchIdentifier(identifier));
  if (element == NULL) return NO;

  AXError error = AXUIElementPerformAction(element, kAXPressAction);
  CFRelease(element);

  return error == kAXErrorSuccess;
}

static AXUIElementRef ChooserPopup(AXUIElementRef application) {
  for (id window in ElementsAttribute(application, kAXWindowsAttribute)) {
    AXUIElementRef found = FindElement((__bridge AXUIElementRef)window, kChooserSearchDepth,
                                       MatchIdentifier(@"ChooserPopUp"));
    if (found != NULL) return found;
  }

  return NULL;
}

#pragma mark - Device names

// Live marks the active choice in the chooser. Only that leading mark (and the
// space after it) is removed — the rest of the title is the device's name
// exactly as Live displays it, and `set-output` matches against it.
static NSString *StripCheckmark(NSString *title) {
  NSCharacterSet *marks =
      [NSCharacterSet characterSetWithCharactersInString:@"✓✔√• \t"];

  NSUInteger index = 0;
  while (index < title.length && [marks characterIsMember:[title characterAtIndex:index]]) index++;

  return index > 0 ? [title substringFromIndex:index] : title;
}

// The chooser's items. `AXMenuItem` is the semantic answer; the pressable-title
// fallback exists because a Live release could reasonably re-role them without
// changing anything a user would notice, and an empty device list is a worse
// failure than a slightly wider match.
static NSArray<NSString *> *ChooserItemTitles(AXUIElementRef chooser,
                                              NSMutableArray *elementsOut) {
  NSMutableArray *items = [NSMutableArray array];
  CollectElements(chooser, kChooserSearchDepth, MatchRole((__bridge NSString *)kAXMenuItemRole),
                  items);

  if (items.count == 0) {
    CollectElements(chooser, kChooserSearchDepth, ^BOOL(AXUIElementRef element) {
      return StringAttribute(element, kAXTitleAttribute).length > 0 && SupportsPress(element);
    }, items);
  }

  NSMutableArray<NSString *> *titles = [NSMutableArray array];
  for (id item in items) {
    NSString *title = StringAttribute((__bridge AXUIElementRef)item, kAXTitleAttribute);
    if (title.length == 0) continue;

    [titles addObject:StripCheckmark(title)];
    [elementsOut addObject:item];
  }

  return titles;
}

// `Use System Device` is the one choice whose resulting value is not its own
// title: Live resolves it and displays `Use System: <the macOS device>`.
static BOOL ValueReflects(NSString *value, NSString *choice) {
  if (value.length == 0) return NO;

  if ([choice caseInsensitiveCompare:@"Use System Device"] == NSOrderedSame) {
    return [value.lowercaseString hasPrefix:@"use system:"] ||
           [value caseInsensitiveCompare:@"Use System Device"] == NSOrderedSame;
  }

  return [value caseInsensitiveCompare:choice] == NSOrderedSame;
}

#pragma mark - The audio-output transaction

// One helper invocation owns one complete UI transaction: activate, open what
// it must, act, verify by reading Live's own value back, and put every piece of
// UI it touched back the way it found it — on the error paths too.
static NSDictionary *AudioOutputTransaction(BOOL setting, NSString *wanted) {
  NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @NO};
  if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
    return Failure(kCodePermissionRequired,
                   @"This helper is not trusted for Accessibility control.");
  }

  NSRunningApplication *live = RunningLive();
  if (live == nil) return Failure(kCodeLiveNotRunning, @"Ableton Live is not running.");

  NSRunningApplication *previousFrontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
  if ([previousFrontmost isEqual:live]) previousFrontmost = nil;

  AXUIElementRef application = AXUIElementCreateApplication(live.processIdentifier);
  AXUIElementSetMessagingTimeout(application, kMessagingTimeout);

  // Live exposes only its menu bar while inactive — zero AX windows — and
  // ignores a menu press while it is behind another application, so reading
  // Settings at all means bringing it forward first. Activation is
  // unconditional: `activateWithOptions:` is a no-op for an application already
  // in front, and the alternative (trusting a cached flag) is what made every
  // third back-to-back run fail.
  //
  // The wait is bounded by its own budget and then *proceeds regardless*: a run
  // that spent the whole action deadline waiting on activation would have
  // nothing left to do the work with.
  ActivateAndWait(live);

  NSDictionary *result = nil;
  AXUIElementRef settings = NULL;
  AXUIElementRef audioGroup = NULL;
  AXUIElementRef popup = NULL;
  AXUIElementRef chooser = NULL;
  BOOL openedSettings = NO;
  BOOL changedPage = NO;
  NSString *originalPage = nil;

  settings = SettingsWindow(application);
  if (settings == NULL) {
    AXError error = kAXErrorSuccess;

    // The press is retried, not merely waited on. Measured 2026-08-27: on
    // back-to-back runs Live intermittently swallows the `Settings...` press —
    // roughly one run in three, always one that arrived while Live was still
    // settling from the previous run's close. A single press plus a long wait
    // turned that into a four-second `timeout`; pressing again after a second
    // turns it into a normal read. Bounded by the action deadline either way.
    for (NSInteger attempt = 0; settings == NULL && attempt < kSettingsOpenAttempts; attempt++) {
      // Re-activate before every attempt, not only once at the top: Live
      // ignores the press while it is behind another application, and losing
      // the front between the first activation and the press is exactly what
      // the back-to-back runs did.
      ActivateAndWait(live);

      error = PressSettingsMenuItem(application);

      NSTimeInterval waitUntil = Now() + kSettingsOpenWait;
      while (settings == NULL && Now() < waitUntil && !PastDeadline()) {
        Pause();
        settings = SettingsWindow(application);
      }

      if (PastDeadline()) break;
    }

    if (settings == NULL) {
      CFRelease(application);
      return Failure(PastDeadline() ? kCodeTimeout : kCodeSettingsUnavailable,
                     error == kAXErrorSuccess
                         ? @"Live's Settings window did not open."
                         : @"Live's Settings menu item could not be pressed.");
    }

    openedSettings = YES;
  }

  originalPage = SelectedPageIdentifier(settings);

  audioGroup = FindElement(settings, kSettingsSearchDepth, MatchIdentifier(@"audio"));
  if (audioGroup == NULL) {
    if (PressIdentifier(settings, @"audioTabButton")) changedPage = YES;

    while (audioGroup == NULL && !PastDeadline()) {
      Pause();
      audioGroup = FindElement(settings, kSettingsSearchDepth, MatchIdentifier(@"audio"));
    }
  }

  if (audioGroup != NULL) {
    popup = FindElement(audioGroup, kPopupSearchDepth, ^BOOL(AXUIElementRef element) {
      return [StringAttribute(element, kAXDescriptionAttribute)
          isEqualToString:@"Audio Output Device"];
    });
  }

  if (popup == NULL) {
    result = Failure(PastDeadline() ? kCodeTimeout : kCodeSettingsUnavailable,
                     @"Live's Audio Output Device control could not be found in Settings.");
  }

  NSString *previous = nil;
  if (result == nil) {
    previous = StringAttribute(popup, kAXValueAttribute);
    if (previous.length == 0) {
      result = Failure(kCodeAXFailure, @"Live's audio output control reported no readable value.");
    }
  }

  // An already-selected device is a verified success with no UI to open: the
  // popup's own value is the read-back.
  BOOL alreadySelected = result == nil && setting && ValueReflects(previous, wanted);
  if (alreadySelected) {
    result = @{
      @"ok" : @YES,
      @"previous" : previous,
      @"current" : previous,
      @"elapsed_ms" : ElapsedMilliseconds()
    };
  }

  NSMutableArray *itemElements = [NSMutableArray array];
  NSArray<NSString *> *titles = @[];

  if (result == nil) {
    // The names live in the chooser and nowhere else, so both commands open it.
    chooser = ChooserPopup(application);
    if (chooser == NULL) {
      if (AXUIElementPerformAction(popup, kAXPressAction) != kAXErrorSuccess) {
        result = Failure(kCodeAXFailure, @"Live's audio output chooser would not open.");
      } else {
        while (chooser == NULL && !PastDeadline()) {
          Pause();
          chooser = ChooserPopup(application);
        }
      }
    }

    if (result == nil && chooser == NULL) {
      result = Failure(PastDeadline() ? kCodeTimeout : kCodeAXFailure,
                       @"Live's audio output chooser did not appear.");
    }
  }

  if (result == nil) {
    titles = ChooserItemTitles(chooser, itemElements);
    if (titles.count == 0) {
      result = Failure(kCodeAXFailure, @"Live's audio output chooser listed no devices.");
    }
  }

  if (result == nil && !setting) {
    result = @{
      @"ok" : @YES,
      @"current" : previous,
      @"devices" : titles,
      @"elapsed_ms" : ElapsedMilliseconds()
    };
  }

  if (result == nil) {
    NSUInteger match = NSNotFound;
    for (NSUInteger index = 0; index < titles.count && match == NSNotFound; index++) {
      // Case-insensitive *exact* match, never fuzzy: resolving "headphones" to
      // a device is the model's job, and a helper that guessed would make a
      // wrong guess indistinguishable from a right one.
      if ([titles[index] caseInsensitiveCompare:wanted] == NSOrderedSame) match = index;
    }

    if (match == NSNotFound) {
      result = @{
        @"ok" : @NO,
        @"code" : kCodeDeviceNotFound,
        @"message" : [NSString stringWithFormat:@"Ableton Live has no audio output called \"%@\".",
                                                wanted],
        @"current" : previous,
        @"devices" : titles,
        @"elapsed_ms" : ElapsedMilliseconds()
      };
    } else {
      AXUIElementRef choice = (__bridge AXUIElementRef)itemElements[match];
      AXError error = AXUIElementPerformAction(choice, kAXPressAction);
      CFRelease(chooser);
      chooser = NULL;

      if (error != kAXErrorSuccess) {
        result = Failure(kCodeAXFailure, @"Live rejected the audio output selection.");
      } else {
        // Success is the popup's observed value, never the press returning
        // zero. The element is re-read rather than cached: the chooser window
        // closing is a window transition.
        NSString *current = nil;
        while (!PastDeadline()) {
          current = StringAttribute(popup, kAXValueAttribute);
          if (ValueReflects(current, titles[match])) break;
          Pause();
        }

        result = ValueReflects(current, titles[match])
                     ? @{
                         @"ok" : @YES,
                         @"previous" : previous,
                         @"current" : current,
                         @"elapsed_ms" : ElapsedMilliseconds()
                       }
                     : Failure(kCodeTimeout,
                               @"Live did not report the new audio output after the selection.");
      }
    }
  }

  // --- Cleanup: every path, success and failure alike ---

  if (chooser != NULL) {
    AXUIElementPerformAction(popup, kAXCancelAction);
    AXUIElementPerformAction(chooser, kAXCancelAction);
    CFRelease(chooser);
  }

  if (changedPage && !openedSettings && originalPage.length > 0) {
    PressIdentifier(settings, originalPage);
  }

  if (openedSettings) {
    CFTypeRef closeButton = CopyAttribute(settings, kAXCloseButtonAttribute);
    if (closeButton != NULL) {
      AXUIElementPerformAction((AXUIElementRef)closeButton, kAXPressAction);
      CFRelease(closeButton);
    }
  }

  if (popup != NULL) CFRelease(popup);
  if (audioGroup != NULL) CFRelease(audioGroup);
  if (settings != NULL) CFRelease(settings);
  CFRelease(application);

  // Waited on, not fired and forgotten: "restores the prior application" is a
  // promise the tool description makes, and an unobserved restore also leaks
  // into the next call's activation (see kRestoreBudget).
  if (previousFrontmost != nil) {
    [previousFrontmost activateWithOptions:0];

    NSTimeInterval until = Now() + kRestoreBudget;
    while (LiveIsFrontmost(live) && Now() < until) Pause();
  }

  return result;
}

#pragma mark - Entry point

static NSString *ArgumentValue(NSArray<NSString *> *arguments, NSString *flag) {
  NSUInteger index = [arguments indexOfObject:flag];
  if (index == NSNotFound || index + 1 >= arguments.count) return nil;

  return arguments[index + 1];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    gStartedAt = Now();
    gDeadline = gStartedAt + kActionDeadline;

    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (int index = 1; index < argc; index++) {
      [arguments addObject:@(argv[index])];
    }

    NSString *command = arguments.firstObject;

    if ([command isEqualToString:@"version"]) {
      return Emit(@{@"ok" : @YES});
    }

    if ([command isEqualToString:@"permission"]) {
      // Only this command may open macOS's setup UI, and only when the
      // installer asks: an ordinary tool call must never make System Settings
      // appear behind the user's back.
      BOOL prompt = [arguments containsObject:@"--prompt"];
      NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @(prompt)};
      BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

      if (trusted) return Emit(@{@"ok" : @YES, @"trusted" : @YES});

      return Emit(@{
        @"ok" : @NO,
        @"code" : kCodePermissionRequired,
        @"trusted" : @NO,
        @"message" : @"This helper is not trusted for Accessibility control."
      });
    }

    if ([command isEqualToString:@"list-outputs"]) {
      return Emit(AudioOutputTransaction(NO, nil));
    }

    if ([command isEqualToString:@"set-output"]) {
      NSString *device = ArgumentValue(arguments, @"--device");
      if (device.length == 0) {
        return Emit(Failure(kCodeUsage, @"set-output requires --device <name>."));
      }

      return Emit(AudioOutputTransaction(YES, device));
    }

    return Emit(Failure(kCodeUsage,
                        @"Usage: seshat-ax version | permission [--prompt] | list-outputs | "
                        @"set-output --device <name>"));
  }
}
