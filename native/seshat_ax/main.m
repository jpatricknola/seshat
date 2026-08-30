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
// no tree dump, no keystroke, no coordinate click. The whole protocol is five
// commands:
//
//   seshat-ax version
//   seshat-ax permission [--prompt]
//   seshat-ax list-outputs
//   seshat-ax set-output --device "<exact display name>"
//   seshat-ax convert --command "<one of three compiled-in menu titles>"
//
// `convert` is the second capability here, added for Live's
// `Create > Convert … to New MIDI Track` commands, which are menu-only at every
// spelling of the Live Object Model (docs/PLAN_sing_it_back_as_midi.md). It is
// closed the same way everything else is: the title must be one of three
// strings compiled in below, so this stays a helper with two operations rather
// than becoming the "press this menu item" primitive the protocol exists to not
// offer.
//
// Every command prints exactly one JSON document on stdout and nothing else —
// no human log text is mixed into the protocol, because `Seshat.AX.Client`
// parses the whole of stdout as one document. Success is
//
//   {"ok":true, ...,"protocol_version":2}
//
// and failure is one shape with a non-zero exit status:
//
//   {"ok":false,"code":"permission_required","message":"…","protocol_version":2}
//
// Codes: permission_required, live_not_running, settings_unavailable,
// device_not_found, ax_failure, timeout, command_unavailable, unknown_command.
// `device_not_found` also carries the names that *are* available, so the model
// can recover in the same turn rather than guessing again.
//
// The selector path is bounded and semantic — the one measured in the
// 2026-08-03 spike. Live is found by bundle identifier (the bundle is named
// `Live`, not `Ableton Live`), activated (Live reports zero AX windows while
// inactive), and its Settings window, `audio` group, `Audio Output Device`
// popup and `ChooserPopUp` menu are all located by identifier, description or
// role. No step falls back to sibling order or coordinates. Every UI change the
// helper makes, it undoes: a chooser it opened is dismissed, a Settings page it
// switched is switched back, a Settings window it opened is closed, and the
// application that was frontmost when it started is brought back — on every
// exit from AudioOutputTransaction, success or failure, not only the ones that
// got as far as reading a value. That used to not be true: an early `return`
// on a Settings window that never opened (a modal dialog in front of it, a
// menu item a future Live relabels) skipped the shared cleanup below and left
// Live frontmost forever (2026-08-27 PR review round). There is now exactly
// one `return NULL`-shaped path out of this function: every failure sets
// `result` and falls through, which is what makes the cleanup block
// unconditional rather than one of several exits to keep in sync.
//
// One monotonic deadline (kActionDeadline) bounds the actionable work —
// everything through observing the result. Restoring the UI afterwards runs
// under its own short budgets (kCleanupBudget, kRestoreBudget) instead of
// inheriting whatever is left of that deadline: a run that timed out
// mid-selection still owes the user their Settings page and their frontmost
// application back, and both restores are bounded by search depth rather than
// by wall time, so extending past the action deadline does not reopen the
// "hung AX call" risk kActionDeadline exists to close. The sum of every phase
// still lands inside the Elixir side's own Port deadline — see the constants
// below.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// Bumped whenever the JSON protocol changes shape. `Seshat.AX.Client` refuses a
// response carrying any other value and names `mix ax.install`, so an installed
// binary left behind by an older checkout fails loudly instead of subtly.
static const int kProtocolVersion = 2;

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

// The cleanup block's own allowance, set as `gDeadline`'s new value right
// before that block runs (see the comment there). Putting a switched Settings
// page back is a bounded-depth search (kSettingsSearchDepth), not an unbounded
// wait, so extending past a spent kActionDeadline cannot hang — it can only
// let a restore that would otherwise bail out on `PastDeadline()` actually run.
// Without this, a run that timed out mid-selection left Settings on the Audio
// page forever, contradicting the promise this file's header makes (2026-08-27
// PR review round).
//
// Deliberately small: the restore it guards is a handful of AX reads on a
// healthy system (microseconds each, per the file header), never a poll or a
// sleep, so it does not need to be anywhere near kRestoreBudget's size to do
// its job. A first cut of 0.6s here (round-1 PR review) left only 300ms
// between the helper's own nominal total and the Elixir side's 5,000ms Port
// timeout — most of the ~900ms margin the file ran with before that change
// existed at all — so this is deliberately cut back to restore most of it:
// 3.5s (kActionDeadline) + 0.1s (this) + 0.6s (kRestoreBudget) is 4.2s
// nominal, ~800ms inside the Elixir side's 5,000ms Port timeout (round-2 PR
// review, 2026-08-27). See `Seshat.AX.Client`'s moduledoc for the matching
// number on the Elixir side.
//
// "Nominal," not a bound: the cleanup calls below (the two `kAXCancelAction`
// sends, the close button's attribute read and press) are not individually
// deadline-gated, so each can cost up to kMessagingTimeout if Live's AX
// implementation hangs rather than answering quickly. 4.2s is what a healthy
// run costs; the actual worst case is bounded by the Elixir side's 5,000ms
// Port timeout, not by anything summed here (round-3 PR review, 2026-08-27).
static const NSTimeInterval kCleanupBudget = 0.1;

// How long to let an opened menu settle before reading `AXEnabled` off one of
// its items. AppKit validates menu items lazily, when the menu opens: measured
// 2026-08-30, every selection-dependent Create item read `false` on a *closed*
// menu regardless of the selection, the clip's type or whether Live was
// active. A reading taken before this wait is worthless, so the wait is part of
// the read rather than a politeness.
static const NSTimeInterval kMenuOpenWait = 0.35;

// How long to let Live act on a picked menu command before counting its
// windows. Convert raised no dialog in the measured run (`windows=1
// [Untitled]` before and 300ms after), and the count is reported either way so
// the Elixir side can refuse to claim success when one appears rather than
// this helper trying to drive it.
static const NSTimeInterval kPickSettleWait = 0.2;

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
static NSString *const kCodeCommandUnavailable = @"command_unavailable";
static NSString *const kCodeUnknownCommand = @"unknown_command";

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
  if ([code isEqualToString:kCodeCommandUnavailable]) return 9;
  if ([code isEqualToString:kCodeUnknownCommand]) return 10;
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
      // Not a `return`: every exit from here on, success or failure, goes
      // through the one cleanup block at the bottom of this function, which is
      // what puts the frontmost application back. Setting `result` instead
      // lets that happen — every block below is already gated on
      // `result == nil`, so nothing further runs, and control falls straight
      // through to cleanup with `settings` still NULL and `openedSettings`
      // still NO, both of which the cleanup block already handles correctly.
      result = Failure(PastDeadline() ? kCodeTimeout : kCodeSettingsUnavailable,
                       error == kAXErrorSuccess
                           ? @"Live's Settings window did not open."
                           : @"Live's Settings menu item could not be pressed.");
    } else {
      openedSettings = YES;
    }
  }

  if (result == nil) {
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
    // Never adopt a chooser that was already open. `ChooserPopUp` identifies
    // Live's chooser implementation, not the Audio Output Device control that
    // opened it, so an unrelated chooser could otherwise be mistaken for the
    // device list. Dismiss anything pre-existing, then open the target popup
    // ourselves so the chooser below has an observed origin.
    chooser = ChooserPopup(application);
    if (chooser != NULL) {
      AXUIElementPerformAction(chooser, kAXCancelAction);
      CFRelease(chooser);
      chooser = NULL;

      while (!PastDeadline()) {
        chooser = ChooserPopup(application);
        if (chooser == NULL) break;

        CFRelease(chooser);
        chooser = NULL;
        Pause();
      }

      AXUIElementRef remainingChooser = ChooserPopup(application);
      if (remainingChooser != NULL) {
        CFRelease(remainingChooser);
        result = Failure(PastDeadline() ? kCodeTimeout : kCodeAXFailure,
                         @"Live's existing chooser would not close.");
      }
    }

    // The names live in the chooser and nowhere else, so both commands open it.
    if (result == nil) {
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

      // `chooser` is deliberately NOT released or nulled here, on either
      // branch below: doing so before the outcome is known left a rejected
      // press (or a press that succeeded but whose read-back then timed out)
      // with the cleanup block's `if (chooser != NULL)` already false, so
      // `kAXCancelAction` was never sent and Live's popup could be left open
      // over the Settings window (round-2 PR review, 2026-08-27 — the same
      // invariant round 1 fixed for the missing-Settings-window path: every
      // exit falls through to the one cleanup block instead of skipping it).
      // The cleanup block below now always runs `kAXCancelAction` against it;
      // that is a harmless no-op on the ordinary success path, where
      // selecting the item has already closed the menu itself.
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

  // From here on, `PastDeadline()` governs restoring the UI, not doing the
  // requested action — and a spent kActionDeadline must not silently cancel
  // the restore. `PressIdentifier` below calls `FindElement`, which bails
  // immediately once `PastDeadline()` is true; without this extension, a run
  // that used up its whole action deadline reaching a result would find
  // `originalPage`'s restore silently do nothing, leaving Settings on the
  // Audio page (2026-08-27 PR review round). kCleanupBudget is a search
  // allowance, not a wait: nothing between here and the function's return
  // polls or sleeps against it.
  //
  // `MAX`, not a plain assignment: a run that reached its result well inside
  // kActionDeadline still has most of that budget left, and a bare `gDeadline
  // = Now() + kCleanupBudget` threw the unspent remainder away on every run,
  // not only a timed-out one — shrinking a fast call's page-restore search to
  // 100ms where it previously had seconds (round-3 PR review, 2026-08-27).
  // `MAX` keeps this line's one job, extending a spent deadline so the restore
  // is not silently skipped, without taking anything from a run that never
  // needed the extension.
  gDeadline = MAX(gDeadline, Now() + kCleanupBudget);

  if (chooser != NULL) {
    AXUIElementPerformAction(popup, kAXCancelAction);
    AXUIElementPerformAction(chooser, kAXCancelAction);
    CFRelease(chooser);
  }

  if (changedPage && originalPage.length > 0) {
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

#pragma mark - The Create-menu transaction

// The only three menu commands this helper may fire, compiled in.
//
// There is deliberately no generic "press the item titled X": that one command
// would make every menu in Live reachable from a tool description and take the
// LOM-first rule with it — UI scripting is for a concrete operation the current
// Live Object Model does not expose, argued case by case, and everything else
// belongs in the AbletonOSC fork. Convert is that case (Live's own
// `Song`/`Clip` APIs have no conversion member at any spelling); adding a
// fourth title here means arguing the same thing again.
// See docs/PLAN_sing_it_back_as_midi.md.
static NSString *const kConvertCommands[] = {
    @"Convert Melody to New MIDI Track",
    @"Convert Harmony to New MIDI Track",
    @"Convert Drums to New MIDI Track",
};

static BOOL IsAllowedConvertCommand(NSString *title) {
  for (NSUInteger index = 0; index < sizeof(kConvertCommands) / sizeof(kConvertCommands[0]);
       index++) {
    if ([kConvertCommands[index] isEqualToString:title]) return YES;
  }

  return NO;
}

// Located by title and role, never by sibling order — the same rule the
// Settings path follows. Depth 2 covers menu bar → menu bar item.
static AXUIElementRef CreateMenuBarItem(AXUIElementRef application) {
  CFTypeRef menuBar = CopyAttribute(application, kAXMenuBarAttribute);
  if (menuBar == NULL) return NULL;

  AXUIElementRef item =
      FindElement((AXUIElementRef)menuBar, 2, ^BOOL(AXUIElementRef element) {
        return [StringAttribute(element, kAXRoleAttribute)
                   isEqualToString:(__bridge NSString *)kAXMenuBarItemRole] &&
               [StringAttribute(element, kAXTitleAttribute) isEqualToString:@"Create"];
      });

  CFRelease(menuBar);

  return item;
}

static AXUIElementRef MenuCommandItem(AXUIElementRef menuBarItem, NSString *title) {
  return FindElement(menuBarItem, kMenuSearchDepth, ^BOOL(AXUIElementRef element) {
    return [StringAttribute(element, kAXRoleAttribute)
               isEqualToString:(__bridge NSString *)kAXMenuItemRole] &&
           [StringAttribute(element, kAXTitleAttribute) isEqualToString:title];
  });
}

// One helper invocation owns one complete menu transaction: activate, open the
// Create menu, read the command's *validated* enabled state, pick it or refuse,
// and leave no menu hanging open. Same shape as AudioOutputTransaction — every
// failure sets `result` and falls through to the one cleanup block, so there is
// exactly one path out and the restore cannot be skipped.
//
// `AXPick`, not `AXPress`, on the command item: that is what was measured to
// fire it (2026-08-30, twice, producing a converted MIDI track both times).
// `AXPress` on a command `AXMenuItem` has never been executed in Live, so it is
// not a substitution to make casually. `AXPress` on the *menu bar* item is what
// opens the menu.
static NSDictionary *ConvertTransaction(NSString *title) {
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

  // Live exposes only its menu bar while inactive and ignores a menu press from
  // behind another application, so everything below is located *after* this.
  ActivateAndWait(live);

  NSDictionary *result = nil;
  AXUIElementRef menuBarItem = NULL;
  AXUIElementRef item = NULL;
  BOOL opened = NO;
  BOOL picked = NO;

  // Counted after activation for the same reason: an inactive Live reports zero
  // windows, which would make every run look as though a window had appeared.
  NSUInteger windowsBefore = ElementsAttribute(application, kAXWindowsAttribute).count;

  menuBarItem = CreateMenuBarItem(application);
  if (menuBarItem == NULL) {
    result = Failure(PastDeadline() ? kCodeTimeout : kCodeAXFailure,
                     @"Ableton Live's Create menu could not be found in its menu bar.");
  }

  if (result == nil) {
    if (AXUIElementPerformAction(menuBarItem, kAXPressAction) != kAXErrorSuccess) {
      result = Failure(kCodeAXFailure, @"Ableton Live's Create menu would not open.");
    } else {
      opened = YES;

      NSTimeInterval until = Now() + kMenuOpenWait;
      while (Now() < until && !PastDeadline()) Pause();
    }
  }

  if (result == nil) {
    item = MenuCommandItem(menuBarItem, title);
    if (item == NULL) {
      result = Failure(
          PastDeadline() ? kCodeTimeout : kCodeAXFailure,
          [NSString stringWithFormat:@"Ableton Live's Create menu has no item called \"%@\".",
                                     title]);
    }
  }

  // The refusal path, and the common one: `AXEnabled` false is the *normal*
  // answer for a selection Live will not convert, so this is not an error to
  // dress up as one.
  if (result == nil && !BooleanAttribute(item, kAXEnabledAttribute)) {
    result = @{
      @"ok" : @NO,
      @"code" : kCodeCommandUnavailable,
      @"message" :
          [NSString stringWithFormat:
                        @"Ableton Live has \"%@\" disabled for what is currently selected.",
                        title],
      @"command" : title,
      @"elapsed_ms" : ElapsedMilliseconds()
    };
  }

  if (result == nil) {
    if (AXUIElementPerformAction(item, kAXPickAction) != kAXErrorSuccess) {
      result = Failure(kCodeAXFailure,
                       [NSString stringWithFormat:@"Ableton Live rejected \"%@\".", title]);
    } else {
      picked = YES;

      NSTimeInterval until = Now() + kPickSettleWait;
      while (Now() < until && !PastDeadline()) Pause();

      result = @{
        @"ok" : @YES,
        @"command" : title,
        @"windows_before" : @(windowsBefore),
        @"windows_after" : @(ElementsAttribute(application, kAXWindowsAttribute).count),
        @"elapsed_ms" : ElapsedMilliseconds()
      };
    }
  }

  // --- Cleanup: every path, success and failure alike ---
  //
  // Same extension as AudioOutputTransaction's, and for the same reason: a run
  // that spent its action deadline still owes the user a closed menu and their
  // frontmost application back.
  gDeadline = MAX(gDeadline, Now() + kCleanupBudget);

  // Picking closes the menu itself. Every other exit — a disabled command, a
  // missing item, a spent deadline — leaves it hanging open over the user's
  // session unless this cancels it.
  if (opened && !picked && menuBarItem != NULL) {
    AXUIElementPerformAction(menuBarItem, kAXCancelAction);
  }

  if (item != NULL) CFRelease(item);
  if (menuBarItem != NULL) CFRelease(menuBarItem);
  CFRelease(application);

  // Waited on, not fired and forgotten: an unobserved restore lands during the
  // next run and breaks it (see kRestoreBudget).
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

    if ([command isEqualToString:@"convert"]) {
      NSString *requested = ArgumentValue(arguments, @"--command");
      if (requested.length == 0) {
        return Emit(Failure(kCodeUsage, @"convert requires --command <menu item title>."));
      }

      // Rejected before Accessibility is touched at all, and deliberately
      // without echoing the requested title: argv is the one place text reaches
      // this program unbounded, and the protocol carries names it read from
      // Live, never names it was handed.
      if (!IsAllowedConvertCommand(requested)) {
        return Emit(@{
          @"ok" : @NO,
          @"code" : kCodeUnknownCommand,
          @"message" : @"This helper only fires Ableton Live's three Create > Convert commands: "
                       @"Convert Melody to New MIDI Track, Convert Harmony to New MIDI Track, "
                       @"Convert Drums to New MIDI Track."
        });
      }

      return Emit(ConvertTransaction(requested));
    }

    return Emit(Failure(kCodeUsage,
                        @"Usage: seshat-ax version | permission [--prompt] | list-outputs | "
                        @"set-output --device <name> | convert --command <menu item title>"));
  }
}
