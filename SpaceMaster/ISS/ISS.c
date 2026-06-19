#include "include/ISS.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGEventTypes.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <float.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const CGEventField kCGSEventTypeField = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType = (CGEventField)110;
static const CGEventField kCGEventGestureScrollY = (CGEventField)119;
static const CGEventField kCGEventGestureSwipeMotion = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kCGEventGesturePhase = (CGEventField)132;
static const CGEventField kCGEventScrollGestureFlagBits = (CGEventField)135;
static const CGEventField kCGEventGestureZoomDeltaX = (CGEventField)139;
static const CGEventField kCGEventSyntheticMarker = (CGEventField)200;
static const int64_t kSyntheticMarkerValue = 0x535357495045LL;
static const int64_t kISSVirtualKeyANSI_A = 0x00;
static const int64_t kISSVirtualKeyANSI_S = 0x01;
static const double kISSInstantGestureVelocity = 999999.0;

// See IOHIDEventType enum in IOHIDFamily
static const uint32_t kIOHIDEventTypeDockSwipe = 23;

typedef uint32_t CGSEventType;
enum {
    kCGSEventScrollWheel = 22,
    kCGSEventZoom = 28,
    kCGSEventGesture = 29,
    kCGSEventDockControl = 30,
    kCGSEventFluidTouchGesture = 31,
};

typedef CF_ENUM(uint8_t, CGSGesturePhase) {
    kCGSGesturePhaseNone = 0,
    kCGSGesturePhaseBegan = 1,
    kCGSGesturePhaseChanged = 2,
    kCGSGesturePhaseEnded = 4,
    kCGSGesturePhaseCancelled = 8,
    kCGSGesturePhaseMayBegin = 128,
};

// Limited subset of motion constants observed in synthetic Dock swipe traces.
typedef CF_ENUM(uint16_t, CGGestureMotion) {
    kCGGestureMotionHorizontal = 1,
};

typedef int32_t CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID connection, CFStringRef display) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID connection) __attribute__((weak_import));
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID connection) __attribute__((weak_import));

static CFMachPortRef globalTap = NULL;
static CFRunLoopSourceRef globalSource = NULL;
static ISSSpaceNavigationShortcutCallback spaceNavigationShortcutCallback = NULL;
static void *spaceNavigationShortcutContext = NULL;
static bool spaceNavigationShortcutEnabled = true;

static bool extract_space_snapshot_from_display(CFDictionaryRef displayDict,
                                                CGSSpaceID activeSpace,
                                                bool hasActiveSpace,
                                                ISSSpaceSnapshot *outSnapshot,
                                                ISSSpaceSnapshotEntry *outSpaces,
                                                unsigned int maxSpaces);
static bool load_space_snapshot_for_display(ISSSpaceSnapshot *outSnapshot,
                                            ISSSpaceSnapshotEntry *outSpaces,
                                            unsigned int maxSpaces,
                                            bool useCursorDisplay);
static bool load_space_info_for_display(ISSSpaceInfo *info, bool useCursorDisplay);
static bool iss_post_switch_gesture(ISSDirection direction);
static bool iss_post_dock_swipe_phase(CGSGesturePhase phase, ISSDirection direction, double velocity);
static int64_t iss_dock_swipe_flag_bits(ISSDirection direction);
static bool iss_switch_with_info(const ISSSpaceInfo *info, ISSDirection direction);
static bool iss_switch_to_index_with_info(const ISSSpaceInfo *info, unsigned int targetIndex);
static bool iss_should_block_switch(const ISSSpaceInfo *info, ISSDirection direction);
static bool iss_space_navigation_shortcut_for_event(CGEventType type,
                                                    CGEventRef event,
                                                    ISSDirection *outDirection);

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, 
                                   CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (globalTap) {
            CGEventTapEnable(globalTap, true);
        }
        return event;
    }

    ISSDirection direction;
    if (spaceNavigationShortcutCallback &&
        spaceNavigationShortcutEnabled &&
        iss_space_navigation_shortcut_for_event(type, event, &direction)) {
        spaceNavigationShortcutCallback(direction, spaceNavigationShortcutContext);

        return NULL;
    }

    return event;
}

static bool iss_space_navigation_shortcut_for_event(CGEventType type,
                                                    CGEventRef event,
                                                    ISSDirection *outDirection) {
    if (type != kCGEventKeyDown || !event || !outDirection) {
        return false;
    }

    const CGEventFlags flags = CGEventGetFlags(event);
    const bool isLeftOptionDown = (flags & NX_DEVICELALTKEYMASK) != 0;
    if (!isLeftOptionDown) {
        return false;
    }

    const CGEventFlags blockedModifiers =
        kCGEventFlagMaskCommand |
        kCGEventFlagMaskControl |
        kCGEventFlagMaskShift |
        kCGEventFlagMaskSecondaryFn;
    if ((flags & blockedModifiers) != 0) {
        return false;
    }

    const int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keyCode == kISSVirtualKeyANSI_A) {
        *outDirection = ISSDirectionLeft;
    } else if (keyCode == kISSVirtualKeyANSI_S) {
        *outDirection = ISSDirectionRight;
    } else {
        return false;
    }

    return true;
}

static bool cgs_symbols_available(void) {
    return (&CGSMainConnectionID != NULL) &&
           (&CGSGetActiveSpace != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}

static void populate_space_uuid(CFDictionaryRef spaceDict, ISSSpaceSnapshotEntry *outSpace) {
    if (!spaceDict || !outSpace) {
        return;
    }

    outSpace->hasUUID = false;
    outSpace->uuid[0] = '\0';

    CFStringRef uuidString = (CFStringRef)CFDictionaryGetValue(spaceDict, CFSTR("uuid"));
    if (!uuidString || CFGetTypeID(uuidString) != CFStringGetTypeID() || CFStringGetLength(uuidString) == 0) {
        return;
    }

    if (CFStringGetCString(uuidString, outSpace->uuid, sizeof(outSpace->uuid), kCFStringEncodingUTF8)) {
        outSpace->hasUUID = true;
        return;
    }

    outSpace->uuid[0] = '\0';
}

static bool extract_space_snapshot_from_display(CFDictionaryRef displayDict,
                                                CGSSpaceID activeSpace,
                                                bool hasActiveSpace,
                                                ISSSpaceSnapshot *outSnapshot,
                                                ISSSpaceSnapshotEntry *outSpaces,
                                                unsigned int maxSpaces) {
    if (!displayDict || !outSnapshot) {
        return false;
    }

    const void *spacesValue = CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
    if (!spacesValue || CFGetTypeID(spacesValue) != CFArrayGetTypeID()) {
        return false;
    }

    // Try to get current space from display dict (more accurate per-display)
    CGSSpaceID displayActiveSpace = 0;
    const void *currentSpaceValue = CFDictionaryGetValue(displayDict, CFSTR("Current Space"));
    if (currentSpaceValue && CFGetTypeID(currentSpaceValue) == CFDictionaryGetTypeID()) {
        CFDictionaryRef currentSpaceDict = (CFDictionaryRef)currentSpaceValue;
        CFNumberRef currentSpaceID = (CFNumberRef)CFDictionaryGetValue(currentSpaceDict, CFSTR("id64"));
        if (currentSpaceID && CFGetTypeID(currentSpaceID) == CFNumberGetTypeID()) {
            CFNumberGetValue(currentSpaceID, kCFNumberSInt64Type, &displayActiveSpace);
        }
    }
    
    // Use display-specific active space if available, otherwise use global
    CGSSpaceID targetActiveSpace = displayActiveSpace != 0 ? displayActiveSpace : activeSpace;
    bool hasTargetActiveSpace = displayActiveSpace != 0 || hasActiveSpace;

    CFArrayRef spaces = (CFArrayRef)spacesValue;
    const CFIndex rawSpaceCount = CFArrayGetCount(spaces);

    unsigned int totalSpaces = 0;
    unsigned int activeIndex = 0;
    bool foundActive = false;

    for (CFIndex i = 0; i < rawSpaceCount; i++) {
        const void *spaceValue = CFArrayGetValueAtIndex(spaces, i);
        if (!spaceValue || CFGetTypeID(spaceValue) != CFDictionaryGetTypeID()) {
            continue;
        }

        CFDictionaryRef spaceDict = (CFDictionaryRef)spaceValue;
        CFNumberRef idNumber = (CFNumberRef)CFDictionaryGetValue(spaceDict, CFSTR("id64"));
        if (!idNumber || CFGetTypeID(idNumber) != CFNumberGetTypeID()) {
            continue;
        }

        CGSSpaceID candidate = 0;
        if (CFNumberGetValue(idNumber, kCFNumberSInt64Type, &candidate)) {
            if (outSpaces) {
                if (totalSpaces >= maxSpaces) {
                    return false;
                }

                ISSSpaceSnapshotEntry *entry = &outSpaces[totalSpaces];
                memset(entry, 0, sizeof(*entry));
                entry->id64 = candidate;
                populate_space_uuid(spaceDict, entry);
            }

            if (!foundActive && hasTargetActiveSpace && candidate == targetActiveSpace) {
                activeIndex = totalSpaces;
                foundActive = true;
            }
            totalSpaces++;
        }
    }

    if (totalSpaces == 0 || (hasTargetActiveSpace && !foundActive)) {
        return false;
    }

    outSnapshot->spaceCount = totalSpaces;
    outSnapshot->currentIndex = foundActive ? activeIndex : 0;
    return true;
}

static bool load_space_snapshot_for_display(ISSSpaceSnapshot *outSnapshot,
                                            ISSSpaceSnapshotEntry *outSpaces,
                                            unsigned int maxSpaces,
                                            bool useCursorDisplay) {
    if (!cgs_symbols_available()) {
        fprintf(stderr, "ISS: required CGS symbols missing\n");
        return false;
    }

    CGSConnectionID connection = CGSMainConnectionID();
    if (connection == 0) {
        fprintf(stderr, "ISS: CGSMainConnectionID returned 0\n");
        return false;
    }

    CGSSpaceID activeSpace = 0;
    bool hasActiveSpace = false;
    if (&CGSGetActiveSpace != NULL) {
        activeSpace = CGSGetActiveSpace(connection);
        if (activeSpace != 0) {
            hasActiveSpace = true;
        } else {
            fprintf(stderr, "ISS: CGSGetActiveSpace returned 0\n");
            return false;
        }
    }

    // Get display identifier based on mode
    CFStringRef activeDisplayIdentifier = NULL;
    
    if (useCursorDisplay) {
        // Get display where cursor is located
        CGEventRef tempEvent = CGEventCreate(NULL);
        CGPoint cursorLocation = CGEventGetLocation(tempEvent);
        CFRelease(tempEvent);
        
        CGDirectDisplayID cursorDisplay = 0;
        uint32_t cursorDisplayCount = 0;
        
        if (CGGetDisplaysWithPoint(cursorLocation, 1, &cursorDisplay, &cursorDisplayCount) == kCGErrorSuccess && cursorDisplayCount > 0) {
            CFUUIDRef displayUUID = CGDisplayCreateUUIDFromDisplayID(cursorDisplay);
            if (displayUUID) {
                activeDisplayIdentifier = CFUUIDCreateString(NULL, displayUUID);
                CFRelease(displayUUID);
            }
        }
    } else {
        // Get menubar display
        if (&CGSCopyActiveMenuBarDisplayIdentifier != NULL) {
            activeDisplayIdentifier = CGSCopyActiveMenuBarDisplayIdentifier(connection);
        }
    }

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(connection, activeDisplayIdentifier);
    if (!displays && activeDisplayIdentifier) {
        displays = CGSCopyManagedDisplaySpaces(connection, NULL);
    }
    if (!displays) {
        if (activeDisplayIdentifier) {
            CFRelease(activeDisplayIdentifier);
        }
        return false;
    }

    const CFIndex displayCount = CFArrayGetCount(displays);
    CFDictionaryRef targetDisplay = NULL;
    CFDictionaryRef fallbackDisplay = NULL;

    for (CFIndex i = 0; i < displayCount; i++) {
        const void *displayValue = CFArrayGetValueAtIndex(displays, i);
        if (!displayValue || CFGetTypeID(displayValue) != CFDictionaryGetTypeID()) {
            continue;
        }

        CFDictionaryRef displayDict = (CFDictionaryRef)displayValue;

        if (!fallbackDisplay) {
            fallbackDisplay = displayDict;
        }

        if (!activeDisplayIdentifier || targetDisplay) {
            continue;
        }

        CFStringRef identifier = (CFStringRef)CFDictionaryGetValue(displayDict, CFSTR("Display Identifier"));
        if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID() && CFEqual(identifier, activeDisplayIdentifier)) {
            targetDisplay = displayDict;
        }
    }

    if (!targetDisplay) {
        targetDisplay = fallbackDisplay;
    }

    bool success = false;
    if (targetDisplay) {
        success = extract_space_snapshot_from_display(
            targetDisplay,
            activeSpace,
            hasActiveSpace,
            outSnapshot,
            outSpaces,
            maxSpaces
        );
    }

    if (activeDisplayIdentifier) {
        CFRelease(activeDisplayIdentifier);
    }
    CFRelease(displays);

    return success;
}

static bool load_space_info_for_display(ISSSpaceInfo *info, bool useCursorDisplay) {
    ISSSpaceSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));

    if (!load_space_snapshot_for_display(&snapshot, NULL, 0, useCursorDisplay)) {
        return false;
    }

    info->currentIndex = snapshot.currentIndex;
    info->spaceCount = snapshot.spaceCount;
    return true;
}

static bool iss_should_block_switch(const ISSSpaceInfo *info, ISSDirection direction) {
    if (!info) {
        return false;
    }
    if (info->spaceCount == 0) {
        return true;
    }

    if (direction == ISSDirectionLeft) {
        return info->currentIndex == 0;
    }

    return info->currentIndex + 1 >= info->spaceCount;
}

bool iss_can_move(ISSSpaceInfo info, ISSDirection direction) {
    return !iss_should_block_switch(&info, direction);
}

void iss_set_space_navigation_shortcut_callback(ISSSpaceNavigationShortcutCallback callback, void *context) {
    spaceNavigationShortcutCallback = callback;
    spaceNavigationShortcutContext = context;
}

void iss_set_space_navigation_shortcut_enabled(bool enabled) {
    spaceNavigationShortcutEnabled = enabled;
}

static bool iss_post_switch_gesture(ISSDirection direction) {
    return iss_post_dock_swipe_phase(kCGSGesturePhaseBegan, direction, kISSInstantGestureVelocity) &&
           iss_post_dock_swipe_phase(kCGSGesturePhaseChanged, direction, kISSInstantGestureVelocity) &&
           iss_post_dock_swipe_phase(kCGSGesturePhaseEnded, direction, kISSInstantGestureVelocity);
}

static bool iss_post_dock_swipe_phase(CGSGesturePhase phase, ISSDirection direction, double velocity) {
    const bool isRight = (direction == ISSDirectionRight);
    const double velocityX = isRight ? velocity : -velocity;
    const int64_t flagBits = iss_dock_swipe_flag_bits(direction);

    CGEventRef gestureEvent = CGEventCreate(NULL);
    if (!gestureEvent) {
        return false;
    }

    CGEventRef dockEvent = CGEventCreate(NULL);
    if (!dockEvent) {
        CFRelease(gestureEvent);
        return false;
    }

    CGEventSetIntegerValueField(gestureEvent, kCGSEventTypeField, kCGSEventGesture);
    CGEventSetIntegerValueField(gestureEvent, kCGEventSyntheticMarker, kSyntheticMarkerValue);

    CGEventSetIntegerValueField(dockEvent, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(dockEvent, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(dockEvent, kCGEventGesturePhase, phase);
    CGEventSetIntegerValueField(dockEvent, kCGEventScrollGestureFlagBits, flagBits);
    CGEventSetIntegerValueField(dockEvent, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(dockEvent, kCGEventGestureScrollY, 0);
    CGEventSetDoubleValueField(dockEvent, kCGEventGestureSwipeVelocityX, velocityX);
    CGEventSetDoubleValueField(dockEvent, kCGEventGestureSwipeVelocityY, 0);
    CGEventSetDoubleValueField(dockEvent, kCGEventGestureZoomDeltaX, FLT_TRUE_MIN);
    CGEventSetIntegerValueField(dockEvent, kCGEventSyntheticMarker, kSyntheticMarkerValue);

    CGEventPost(kCGSessionEventTap, dockEvent);
    CGEventPost(kCGSessionEventTap, gestureEvent);

    CFRelease(gestureEvent);
    CFRelease(dockEvent);

    return true;
}

static int64_t iss_dock_swipe_flag_bits(ISSDirection direction) {
    float flagsProgress = FLT_TRUE_MIN;
    if (direction == ISSDirectionLeft) {
        flagsProgress = -flagsProgress;
    }

    int32_t bits = 0;
    memcpy(&bits, &flagsProgress, sizeof(bits));
    return (int64_t)bits;
}

bool iss_init(void) {
    if (globalTap) {
        return true;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    globalTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        eventTapCallback,
        NULL
    );

    if (!globalTap) {
        return false;
    }

    globalSource = CFMachPortCreateRunLoopSource(NULL, globalTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), globalSource, kCFRunLoopCommonModes);
    CGEventTapEnable(globalTap, true);

    return true;
}

void iss_destroy(void) {
    if (globalTap) {
        CGEventTapEnable(globalTap, false);
        if (globalSource) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalSource, kCFRunLoopCommonModes);
            CFRelease(globalSource);
            globalSource = NULL;
        }
        CFRelease(globalTap);
        globalTap = NULL;
    }
}

bool iss_get_space_info(ISSSpaceInfo *info) {
    if (!info) {
        return false;
    }

    memset(info, 0, sizeof(*info));
    return load_space_info_for_display(info, true);
}

bool iss_get_menubar_space_info(ISSSpaceInfo *info) {
    if (!info) {
        return false;
    }

    memset(info, 0, sizeof(*info));
    return load_space_info_for_display(info, false);
}

bool iss_copy_menubar_space_snapshot(ISSSpaceSnapshot *outSnapshot,
                                     ISSSpaceSnapshotEntry *outSpaces,
                                     unsigned int maxSpaces) {
    if (!outSnapshot || !outSpaces || maxSpaces == 0) {
        return false;
    }

    memset(outSnapshot, 0, sizeof(*outSnapshot));
    memset(outSpaces, 0, sizeof(*outSpaces) * maxSpaces);
    return load_space_snapshot_for_display(outSnapshot, outSpaces, maxSpaces, false);
}

bool iss_copy_cursor_space_snapshot(ISSSpaceSnapshot *outSnapshot,
                                    ISSSpaceSnapshotEntry *outSpaces,
                                    unsigned int maxSpaces) {
    if (!outSnapshot || !outSpaces || maxSpaces == 0) {
        return false;
    }

    memset(outSnapshot, 0, sizeof(*outSnapshot));
    memset(outSpaces, 0, sizeof(*outSpaces) * maxSpaces);
    return load_space_snapshot_for_display(outSnapshot, outSpaces, maxSpaces, true);
}

const char *iss_space_snapshot_entry_uuid(const ISSSpaceSnapshotEntry *space) {
    if (!space || !space->hasUUID || space->uuid[0] == '\0') {
        return NULL;
    }

    return space->uuid;
}

bool iss_get_space_count_for_uuid(const char *uuidCStr, unsigned int *outCount) {
    if (!uuidCStr || !outCount) return false;
    if (!cgs_symbols_available()) return false;

    CGSConnectionID connection = CGSMainConnectionID();
    if (connection == 0) return false;

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(connection, NULL);
    if (!displays) return false;

    CFStringRef targetUUID = CFStringCreateWithCString(NULL, uuidCStr, kCFStringEncodingUTF8);
    bool found = false;

    const CFIndex displayCount = CFArrayGetCount(displays);
    for (CFIndex i = 0; i < displayCount; i++) {
        const void *displayValue = CFArrayGetValueAtIndex(displays, i);
        if (!displayValue || CFGetTypeID(displayValue) != CFDictionaryGetTypeID()) continue;

        CFDictionaryRef displayDict = (CFDictionaryRef)displayValue;
        CFStringRef identifier = (CFStringRef)CFDictionaryGetValue(displayDict, CFSTR("Display Identifier"));
        if (!identifier || CFGetTypeID(identifier) != CFStringGetTypeID()) continue;
        if (!CFEqual(identifier, targetUUID)) continue;

        const void *spacesValue = CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
        if (spacesValue && CFGetTypeID(spacesValue) == CFArrayGetTypeID()) {
            *outCount = (unsigned int)CFArrayGetCount((CFArrayRef)spacesValue);
            found = true;
        }
        break;
    }

    CFRelease(targetUUID);
    CFRelease(displays);
    return found;
}

static bool iss_switch_with_info(const ISSSpaceInfo *info, ISSDirection direction) {
    if (iss_should_block_switch(info, direction)) {
        return false;
    }
    if (!iss_post_switch_gesture(direction)) {
        return false;
    }

    return true;
}

bool iss_switch(ISSDirection direction) {
    ISSSpaceInfo info;
    if (iss_get_space_info(&info)) {
        return iss_switch_with_info(&info, direction);
    }

    return iss_post_switch_gesture(direction);
}

bool iss_switch_to_index(unsigned int targetIndex) {
    ISSSpaceInfo info;
    if (!iss_get_space_info(&info)) {
        return false;
    }

    return iss_switch_to_index_with_info(&info, targetIndex);
}

bool iss_switch_to_index_on_menubar(unsigned int targetIndex) {
    ISSSpaceInfo info;
    if (!iss_get_menubar_space_info(&info)) {
        return false;
    }

    return iss_switch_to_index_with_info(&info, targetIndex);
}

static bool iss_switch_to_index_with_info(const ISSSpaceInfo *info, unsigned int targetIndex) {
    if (!info || info->spaceCount == 0) {
        return false;
    }

    bool outOfBounds = targetIndex >= info->spaceCount;
    if (outOfBounds) {
        targetIndex = info->spaceCount - 1;
    }

    if (info->currentIndex == targetIndex) {
        return !outOfBounds;
    }

    ISSDirection direction = info->currentIndex < targetIndex ? ISSDirectionRight : ISSDirectionLeft;
    unsigned int steps = direction == ISSDirectionRight ? (targetIndex - info->currentIndex) : (info->currentIndex - targetIndex);

    for (unsigned int i = 0; i < steps; i++) {
        if (!iss_post_switch_gesture(direction)) {
            return false;
        }
    }

    return !outOfBounds;
}
