#ifndef ISS_h
#define ISS_h

#include <stdbool.h>
#include <stdint.h>

enum {
    ISSSpaceSnapshotMaxEntries = 128,
    ISSSpaceUUIDBufferLength = 37
};

/** @brief Initialize resources
 * @return true on success, false on failure
 */
bool iss_init(void);

/** @brief Clean up resources */
void iss_destroy(void);

/** @brief The direction to switch spaces towards */
typedef enum {
    ISSDirectionLeft = 0,
    ISSDirectionRight = 1
} ISSDirection;

typedef void (*ISSSpaceNavigationShortcutCallback)(ISSDirection direction, void *context);

/**
 * @brief Describes the current space state for the active display.
 */
typedef struct {
    unsigned int currentIndex; /**< Zero-based index of the active space */
    unsigned int spaceCount;   /**< Total number of user-visible spaces */
} ISSSpaceInfo;

/**
 * @brief Describes one visible user space in the current snapshot.
 */
typedef struct {
    uint64_t id64;                             /**< Stable space id exposed by CGS */
    bool hasUUID;                              /**< Whether uuid contains a non-empty value */
    char uuid[ISSSpaceUUIDBufferLength];       /**< Null-terminated space UUID when present */
} ISSSpaceSnapshotEntry;

/**
 * @brief Describes the ordered visible spaces for a display snapshot.
 */
typedef struct {
    unsigned int currentIndex; /**< Zero-based index of the active space */
    unsigned int spaceCount;   /**< Total number of visible spaces in the snapshot */
} ISSSpaceSnapshot;

/**
 * @brief Performs the space switch if the requested move is within bounds.
 * @param direction The direction to switch spaces towards
 * @return true if the switch was posted, false if blocked by bounds or errors
 */
bool iss_switch(ISSDirection direction);

/**
 * @brief Registers a callback for fixed left-option space navigation shortcuts.
 * @param callback Function invoked when the event tap detects a matching shortcut.
 * @param context Caller-owned pointer passed back to callback.
 */
void iss_set_space_navigation_shortcut_callback(ISSSpaceNavigationShortcutCallback callback, void *context);

/**
 * @brief Enables or disables fixed shortcut handling without clearing the callback.
 * @param enabled Whether matching shortcuts should be consumed and dispatched.
 */
void iss_set_space_navigation_shortcut_enabled(bool enabled);

/**
 * @brief Retrieves the current space info for the display where the cursor is located.
 * @param info Output pointer that receives the info struct.
 * @return true on success, false if unavailable (e.g. API failure)
 */
bool iss_get_space_info(ISSSpaceInfo *info);

/**
 * @brief Retrieves the current space info for the active menu-bar display.
 * @param info Output pointer that receives the info struct.
 * @return true on success, false if unavailable (e.g. API failure)
 */
bool iss_get_menubar_space_info(ISSSpaceInfo *info);

/**
 * @brief Copies the visible spaces for the active menu-bar display from a single CGS snapshot.
 * @param outSnapshot Output pointer receiving currentIndex and spaceCount.
 * @param outSpaces Caller-provided buffer that receives ordered visible spaces.
 * @param maxSpaces Capacity of outSpaces.
 * @return true on success, false if unavailable or the provided buffer is too small.
 */
bool iss_copy_menubar_space_snapshot(ISSSpaceSnapshot *outSnapshot,
                                     ISSSpaceSnapshotEntry *outSpaces,
                                     unsigned int maxSpaces);

/**
 * @brief Copies the visible spaces for the display where the cursor is located.
 * @param outSnapshot Output pointer receiving currentIndex and spaceCount.
 * @param outSpaces Caller-provided buffer that receives ordered visible spaces.
 * @param maxSpaces Capacity of outSpaces.
 * @return true on success, false if unavailable or the provided buffer is too small.
 */
bool iss_copy_cursor_space_snapshot(ISSSpaceSnapshot *outSnapshot,
                                    ISSSpaceSnapshotEntry *outSpaces,
                                    unsigned int maxSpaces);

/**
 * @brief Returns the UUID c-string for a snapshot entry when present.
 * @param space Snapshot entry.
 * @return Null when the entry has no UUID.
 */
const char *iss_space_snapshot_entry_uuid(const ISSSpaceSnapshotEntry *space);

/**
 * @brief Determines if a move in the given direction is allowed for the info.
 * @param info Space info snapshot.
 * @param direction Desired direction to move.
 * @return true if the move is permissible.
 */
bool iss_can_move(ISSSpaceInfo info, ISSDirection direction);

/**
 * @brief Attempts to switch directly to the provided space index.
 * @param targetIndex Zero-based index for the desired space.
 * @return true if the request succeeded (already on target or switches posted)
 */
bool iss_switch_to_index(unsigned int targetIndex);

/**
 * @brief Attempts to switch the active menu-bar display directly to the provided space index.
 * @param targetIndex Zero-based index for the desired space.
 * @return true if the request succeeded (already on target or switches posted)
 */
bool iss_switch_to_index_on_menubar(unsigned int targetIndex);

/**
 * @brief Returns the space count for the display identified by a UUID string.
 * @param uuidCStr Null-terminated UUID string (e.g. from CGDisplayCreateUUIDFromDisplayID).
 * @param outCount Output space count.
 * @return true on success.
 */
bool iss_get_space_count_for_uuid(const char *uuidCStr, unsigned int *outCount);

#endif /* ISS_h */
