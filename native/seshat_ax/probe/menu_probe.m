// menu_probe — a read-mostly Accessibility probe for Live's menu bar.
//
// NOT part of the product. `mix ax.install` and the CI build ignore
// native/seshat_ax/probe/ entirely; nothing under lib/ calls this. It exists so
// the measurement behind docs/PLAN_live_native_generation_spike.md and
// docs/PLAN_sing_it_back_as_midi.md Part 1 is reproducible — the 2026-08-03
// ax-probe's source was never kept and only its binary survives.
//
// Build:
//   /usr/bin/clang -fobjc-arc -Wall -Wextra -Werror -O2 \
//     -framework AppKit -framework ApplicationServices \
//     -o _build/ax-spike/menu-probe native/seshat_ax/probe/menu_probe.m
//
// Commands:
//   menu-probe list                 — Create and Edit menus: title | enabled |
//                                     actions. Read-only. No activation.
//   menu-probe press "<title>"      — allowlisted titles only; activates Live,
//                                     presses, restores the previously frontmost
//                                     application, then reports AXWindows 200ms
//                                     later.
//
// Deliberately absent: a whole-tree dump, keystrokes, coordinates, and any
// generic "press this element". A title not on the allowlist exits 2 without
// touching AX.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSArray<NSString *> *AllowedTitles(void) {
    return @[
        @"Separate Stems to New Audio Tracks",
        @"Convert Harmony to New MIDI Track",
        @"Convert Melody to New MIDI Track",
        @"Convert Drums to New MIDI Track",
        @"Slice to New MIDI Track",
        @"Extract Groove(s)",
        @"Bounce Track in Place",
        @"Bounce to New Track",
        // Control experiment only (2026-08-30): a Create-menu command that reads
        // enabled=true unconditionally and leaves evidence on both sides — a new
        // track in Live's UI and a /live/song/get/tracks push over OSC — so the
        // press mechanism can be proven independently of whether Convert is
        // enabled. One undo reverses it. Not a target of the spike.
        @"Insert MIDI Track",
    ];
}

static id CopyAttr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static AXUIElementRef LiveApp(pid_t *pidOut) {
    NSArray<NSRunningApplication *> *apps =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ableton.live"];
    if (apps.count == 0) return NULL;
    pid_t pid = apps.firstObject.processIdentifier;
    if (pidOut) *pidOut = pid;
    return AXUIElementCreateApplication(pid);
}

// Menu bar -> AXMenuBarItem titled `menuName` -> its one AXMenu child ->
// AXMenuItem whose AXTitle equals `itemTitle`. Located by title and role only.
static AXUIElementRef FindMenuItem(AXUIElementRef app, NSString *menuName, NSString *itemTitle) {
    id menuBar = CopyAttr(app, kAXMenuBarAttribute);
    if (!menuBar) return NULL;
    NSArray *barItems = CopyAttr((__bridge AXUIElementRef)menuBar, kAXChildrenAttribute);
    for (id barItem in barItems) {
        AXUIElementRef bi = (__bridge AXUIElementRef)barItem;
        NSString *t = CopyAttr(bi, kAXTitleAttribute);
        if (![t isEqualToString:menuName]) continue;
        NSArray *menus = CopyAttr(bi, kAXChildrenAttribute);
        for (id menu in menus) {
            NSArray *items = CopyAttr((__bridge AXUIElementRef)menu, kAXChildrenAttribute);
            for (id item in items) {
                AXUIElementRef mi = (__bridge AXUIElementRef)item;
                NSString *it = CopyAttr(mi, kAXTitleAttribute);
                if ([it isEqualToString:itemTitle]) return (AXUIElementRef)CFRetain(mi);
            }
        }
    }
    return NULL;
}

static AXUIElementRef FindMenuBarItem(AXUIElementRef app, NSString *menuName) {
    id menuBar = CopyAttr(app, kAXMenuBarAttribute);
    if (!menuBar) return NULL;
    NSArray *barItems = CopyAttr((__bridge AXUIElementRef)menuBar, kAXChildrenAttribute);
    for (id barItem in barItems) {
        AXUIElementRef bi = (__bridge AXUIElementRef)barItem;
        NSString *t = CopyAttr(bi, kAXTitleAttribute);
        if ([t isEqualToString:menuName]) return (AXUIElementRef)CFRetain(bi);
    }
    return NULL;
}

static void ListMenu(AXUIElementRef app, NSString *menuName) {
    printf("== %s ==\n", menuName.UTF8String);
    id menuBar = CopyAttr(app, kAXMenuBarAttribute);
    if (!menuBar) { printf("  (no menu bar)\n"); return; }
    NSArray *barItems = CopyAttr((__bridge AXUIElementRef)menuBar, kAXChildrenAttribute);
    for (id barItem in barItems) {
        AXUIElementRef bi = (__bridge AXUIElementRef)barItem;
        NSString *t = CopyAttr(bi, kAXTitleAttribute);
        if (![t isEqualToString:menuName]) continue;
        NSArray *menus = CopyAttr(bi, kAXChildrenAttribute);
        for (id menu in menus) {
            NSArray *items = CopyAttr((__bridge AXUIElementRef)menu, kAXChildrenAttribute);
            for (id item in items) {
                AXUIElementRef mi = (__bridge AXUIElementRef)item;
                NSString *it = CopyAttr(mi, kAXTitleAttribute);
                if (it.length == 0) continue;
                NSNumber *en = CopyAttr(mi, kAXEnabledAttribute);
                CFArrayRef actions = NULL;
                AXUIElementCopyActionNames(mi, &actions);
                NSArray *acts = actions ? CFBridgingRelease(actions) : @[];
                printf("  %-42s enabled=%-5s actions=%s\n",
                       it.UTF8String,
                       en.boolValue ? "true" : "false",
                       [acts componentsJoinedByString:@","].UTF8String);
            }
        }
    }
}

static void ReportWindows(AXUIElementRef app, const char *when) {
    NSArray *wins = CopyAttr(app, kAXWindowsAttribute);
    printf("windows(%s)=%lu", when, (unsigned long)wins.count);
    for (id w in wins) {
        NSString *t = CopyAttr((__bridge AXUIElementRef)w, kAXTitleAttribute);
        printf(" [%s]", t.length ? t.UTF8String : "(untitled)");
    }
    printf("\n");
}

// Runs the runloop until `check` passes or the deadline expires. Sleeping here
// would never see NSRunningApplication.active change — it is delivered by a
// workspace notification (the 2026-08-27 lesson recorded in main.m).
static BOOL WaitFor(BOOL (^check)(void), NSTimeInterval budget) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:budget];
    while (!check()) {
        if ([[NSDate date] compare:deadline] == NSOrderedDescending) return NO;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (!AXIsProcessTrusted()) {
            printf("ERROR not-trusted: this terminal lacks Accessibility permission\n");
            return 4;
        }
        if (argc < 2) { printf("usage: menu-probe list | press \"<title>\"\n"); return 2; }

        pid_t pid = 0;
        AXUIElementRef app = LiveApp(&pid);
        if (!app) { printf("ERROR live-not-running\n"); return 5; }
        printf("live pid=%d trusted=true\n", pid);

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"list"]) {
            NSRunningApplication *live =
                [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ableton.live"].firstObject;
            printf("live active=%s\n", live.active ? "true" : "false");
            ReportWindows(app, "now");
            // Read-only: does Live expose anything below its window? Decides
            // whether a context menu via AXShowMenu on a clip element is even
            // conceivable, or whether the menu bar is the only AX surface.
            NSArray *wins = CopyAttr(app, kAXWindowsAttribute);
            for (id w in wins) {
                AXUIElementRef win = (__bridge AXUIElementRef)w;
                NSArray *kids = CopyAttr(win, kAXChildrenAttribute);
                printf("window children=%lu\n", (unsigned long)kids.count);
                for (id k in kids) {
                    AXUIElementRef ke = (__bridge AXUIElementRef)k;
                    NSString *role = CopyAttr(ke, kAXRoleAttribute);
                    NSString *desc = CopyAttr(ke, kAXDescriptionAttribute);
                    NSString *ident = CopyAttr(ke, kAXIdentifierAttribute);
                    NSArray *gk = CopyAttr(ke, kAXChildrenAttribute);
                    printf("  role=%s desc=%s id=%s children=%lu\n",
                           role.UTF8String ?: "-", desc.length ? desc.UTF8String : "-",
                           ident.length ? ident.UTF8String : "-",
                           (unsigned long)gk.count);
                }
            }
            ListMenu(app, @"Create");
            ListMenu(app, @"Edit");
            return 0;
        }

        if ([cmd isEqualToString:@"press"]) {
            if (argc < 3) { printf("ERROR no-title\n"); return 2; }
            NSString *title = [NSString stringWithUTF8String:argv[2]];
            if (![AllowedTitles() containsObject:title]) {
                printf("ERROR not-allowlisted: %s\n", title.UTF8String);
                return 2;
            }
            // Convert lives under Create; the Bounce/Groove commands under Edit.
            NSString *menu = [title hasPrefix:@"Bounce"] || [title hasPrefix:@"Extract"]
                ? @"Edit" : @"Create";

            // Read enabled state BEFORE and AFTER activation, and decide on the
            // AFTER reading. macOS does not necessarily revalidate a background
            // application's menus, so a `false` read while Live is inactive is
            // not evidence the command is unavailable — measured 2026-08-30,
            // when an OSC clip selection left every Convert item false until
            // this ordering was corrected.
            AXUIElementRef item = FindMenuItem(app, menu, title);
            if (!item) { printf("ERROR item-not-found in %s\n", menu.UTF8String); return 3; }
            NSNumber *enabled = CopyAttr(item, kAXEnabledAttribute);
            printf("pre-activation: menu=%s enabled=%s\n", menu.UTF8String,
                   enabled.boolValue ? "true" : "false");
            CFRelease(item);

            NSRunningApplication *previous = [NSWorkspace sharedWorkspace].frontmostApplication;
            NSRunningApplication *live =
                [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ableton.live"].firstObject;
            printf("previous-frontmost=%s\n", previous.bundleIdentifier.UTF8String);

            [live activateWithOptions:0];
            BOOL becameActive = WaitFor(^BOOL{ return live.active; }, 2.0);
            printf("activated=%s\n", becameActive ? "true" : "false");

            // Re-locate after activation: the menu bar element is rebuilt when
            // the application becomes frontmost.
            item = FindMenuItem(app, menu, title);
            if (!item) { printf("ERROR item-vanished-after-activation\n"); return 3; }
            NSNumber *enabled2 = CopyAttr(item, kAXEnabledAttribute);
            printf("post-activation enabled=%s (menu still closed)\n",
                   enabled2.boolValue ? "true" : "false");
            CFRelease(item);

            // OPEN THE MENU BEFORE READING ENABLED STATE.
            //
            // AppKit validates menu items lazily — validateMenuItem: runs when a
            // menu is about to be displayed. AXEnabled on a menu that has never
            // been opened reports the un-validated default, so every reading
            // taken without this step is meaningless for selection-dependent
            // commands. This is the same open-then-act shape main.m already uses
            // for the audio-output popup, which is why that path works.
            AXUIElementRef bar = FindMenuBarItem(app, menu);
            if (!bar) { printf("ERROR menubar-item-not-found: %s\n", menu.UTF8String); return 3; }
            AXError openErr = AXUIElementPerformAction(bar, kAXPressAction);
            printf("opened menu %s AXError=%d\n", menu.UTF8String, (int)openErr);
            WaitFor(^BOOL{ return NO; }, 0.35);

            item = FindMenuItem(app, menu, title);
            if (!item) {
                printf("ERROR item-vanished-after-open\n");
                AXUIElementPerformAction(bar, kAXCancelAction);
                CFRelease(bar);
                return 3;
            }
            NSNumber *enabled3 = CopyAttr(item, kAXEnabledAttribute);
            printf("post-open enabled=%s\n", enabled3.boolValue ? "true" : "false");

            if (!enabled3.boolValue) {
                printf("RESULT disabled-with-menu-open — not pressed\n");
                AXUIElementPerformAction(bar, kAXCancelAction);
                CFRelease(bar);
                CFRelease(item);
                [previous activateWithOptions:0];
                WaitFor(^BOOL{ return previous.active; }, 2.0);
                return 3;
            }
            CFRelease(bar);

            NSDate *t0 = [NSDate date];
            AXError err = AXUIElementPerformAction(item, kAXPressAction);
            printf("RESULT press AXError=%d elapsed_ms=%.0f\n",
                   (int)err, [[NSDate date] timeIntervalSinceDate:t0] * 1000.0);
            CFRelease(item);

            WaitFor(^BOOL{ return NO; }, 0.2);
            ReportWindows(app, "200ms-after");

            [previous activateWithOptions:0];
            BOOL restored = WaitFor(^BOOL{ return previous.active; }, 2.0);
            printf("restored-frontmost=%s\n", restored ? "true" : "false");
            return 0;
        }

        // `pick` — attempt kAXPickAction on an allowlisted menu item, opening the
        // menu first, and WITHOUT gating on AXEnabled. The enabled reading is the
        // thing under suspicion here (2026-08-30: every selection-dependent Create
        // item read false regardless of selection, activation, or menu state), so
        // gating on it would beg the question. Performing an action on a genuinely
        // disabled item is a no-op, so attempting it costs nothing.
        if ([cmd isEqualToString:@"pick"]) {
            if (argc < 3) { printf("ERROR no-title\n"); return 2; }
            NSString *title = [NSString stringWithUTF8String:argv[2]];
            if (![AllowedTitles() containsObject:title]) {
                printf("ERROR not-allowlisted: %s\n", title.UTF8String);
                return 2;
            }
            NSString *menu = [title hasPrefix:@"Bounce"] || [title hasPrefix:@"Extract"]
                ? @"Edit" : @"Create";

            NSRunningApplication *previous = [NSWorkspace sharedWorkspace].frontmostApplication;
            NSRunningApplication *live =
                [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ableton.live"].firstObject;
            printf("previous-frontmost=%s\n", previous.bundleIdentifier.UTF8String);
            [live activateWithOptions:0];
            printf("activated=%s\n", WaitFor(^BOOL{ return live.active; }, 2.0) ? "true" : "false");

            AXUIElementRef bar = FindMenuBarItem(app, menu);
            if (!bar) { printf("ERROR menubar-item-not-found: %s\n", menu.UTF8String); return 3; }
            AXError openErr = AXUIElementPerformAction(bar, kAXPressAction);
            printf("opened menu %s AXError=%d\n", menu.UTF8String, (int)openErr);
            WaitFor(^BOOL{ return NO; }, 0.35);

            AXUIElementRef item = FindMenuItem(app, menu, title);
            if (!item) {
                printf("ERROR item-vanished-after-open\n");
                AXUIElementPerformAction(bar, kAXCancelAction);
                CFRelease(bar);
                return 3;
            }
            NSNumber *en = CopyAttr(item, kAXEnabledAttribute);
            printf("post-open enabled=%s (attempting anyway)\n", en.boolValue ? "true" : "false");

            NSDate *t0 = [NSDate date];
            AXError pickErr = AXUIElementPerformAction(item, kAXPickAction);
            printf("RESULT pick AXError=%d elapsed_ms=%.0f\n",
                   (int)pickErr, [[NSDate date] timeIntervalSinceDate:t0] * 1000.0);
            CFRelease(item);

            WaitFor(^BOOL{ return NO; }, 0.3);
            ReportWindows(app, "300ms-after");
            // Close the menu if the pick left it open.
            AXUIElementPerformAction(bar, kAXCancelAction);
            CFRelease(bar);

            [previous activateWithOptions:0];
            printf("restored-frontmost=%s\n",
                   WaitFor(^BOOL{ return previous.active; }, 2.0) ? "true" : "false");
            return 0;
        }

        printf("ERROR unknown-command: %s\n", cmd.UTF8String);
        return 2;
    }
}
