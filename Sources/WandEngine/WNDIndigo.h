// WNDIndigo.h
// Stable envelope for native SimulatorKit packets. Payloads stay opaque.
#ifndef WND_INDIGO_H
#define WND_INDIGO_H

#include <stdint.h>

#pragma pack(push, 4)

// Only the stable 0x20-byte envelope is defined here. Payloads are authored by
// Apple's native builders and sized from this envelope, never reconstructed.
typedef struct {
  uint32_t msgh_bits, msgh_size, msgh_remote_port, msgh_local_port, msgh_voucher_port;
  int32_t msgh_id;
} WNDMachMessageHeader;
typedef struct {
  WNDMachMessageHeader header;
  uint32_t innerSize; // Native payload stride: 0x90 or 0xA0.
  uint8_t eventType;  // Number of payloads.
  uint8_t reserved[3];
} WNDIndigoMessage;
_Static_assert(sizeof(WNDIndigoMessage) == 0x20, "Indigo envelope changed");

#pragma pack(pop)

// Button sources / targets / types (from the Indigo wire format).
#define WND_BUTTON_SOURCE_APPLE_PAY    0x1f4
#define WND_BUTTON_SOURCE_HOME         0x0
#define WND_BUTTON_SOURCE_LOCK         0x1
#define WND_BUTTON_SOURCE_KEYBOARD     0x2710
#define WND_BUTTON_SOURCE_SIDE         0xbb8
#define WND_BUTTON_SOURCE_SIRI         0x400002
#define WND_BUTTON_TARGET_HARDWARE     0x33
#define WND_BUTTON_TARGET_KEYBOARD     0x64
#define WND_BUTTON_TYPE_DOWN           0x1
#define WND_BUTTON_TYPE_UP             0x2

#define WND_INDIGO_EVENTTYPE_BUTTON    1
#define WND_INDIGO_EVENTTYPE_TOUCH     2

#endif // WND_INDIGO_H
