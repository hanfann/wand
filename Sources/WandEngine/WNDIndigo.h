// WNDIndigo.h
// Byte-exact reimplementation of the Indigo HID wire format used by the iOS
// Simulator (SimDeviceLegacyHIDClient -> guest SimHIDVirtualServiceManager).
//
// Layout mirrors SimulatorApp/Indigo.h + Mach.h field-for-field so that
// sizeof()/strides match what the guest dispatcher expects:
//   sizeof(WNDIndigoPayload) == 0x90, sizeof(WNDIndigoMessage) == 0xB0,
//   a touch message is 0x140 bytes (message + one extra payload, stride 0x90).
//
// This is our own implementation. We do not link or call idb/AXe; we talk to
// Apple's SimulatorKit symbols directly. Struct layout is the documented wire
// format, not third-party code.
#ifndef WND_INDIGO_H
#define WND_INDIGO_H

#include <stdint.h>

#pragma pack(push, 4)

typedef struct {
  unsigned int msgh_bits;         // 0x0
  unsigned int msgh_size;         // 0x4
  unsigned int msgh_remote_port;  // 0x8
  unsigned int msgh_local_port;   // 0xc
  unsigned int msgh_voucher_port; // 0x10
  int          msgh_id;           // 0x14
} WNDMachMessageHeader;            // 0x18

typedef struct {
  double field1;
  double field2;
  double field3;
  double field4;
} WNDIndigoQuad; // 0x20

typedef struct {
  unsigned int field1;  // 0x30 (relative to message base)
  unsigned int field2;  // 0x34
  unsigned int field3;  // 0x38
  double       xRatio;  // 0x3c  normalized 0..1 from left
  double       yRatio;  // 0x44  normalized 0..1 from top
  double       field6;  // 0x4c
  double       field7;  // 0x54
  double       field8;  // 0x5c
  unsigned int field9;  // 0x64
  unsigned int field10; // 0x68
  unsigned int field11; // 0x6c
  unsigned int field12; // 0x70
  unsigned int field13; // 0x74
  double       field14; // 0x78
  double       field15; // 0x80
  double       field16; // 0x88
  double       field17; // 0x90
  double       field18; // 0x98
} WNDIndigoTouch; // 0x70 bytes

typedef struct {
  unsigned int field1;
  double       field2;
  double       field3;
  double       field4;
  unsigned int field5;
} WNDIndigoWheel;

typedef struct {
  unsigned int eventSource; // 0x30
  unsigned int eventType;   // 0x34  1=down 2=up
  unsigned int eventTarget; // 0x38  0x33 hardware, 0x64 keyboard
  unsigned int keyCode;     // 0x3c
  unsigned int field5;      // 0x40
} WNDIndigoButton;

typedef struct {
  unsigned int  field1;
  unsigned char field2[40];
} WNDIndigoAccelerometer;

typedef struct {
  unsigned int field1;
  double       field2;
  unsigned int field3;
  double       field4;
} WNDIndigoForce;

typedef struct {
  WNDIndigoQuad dpad;
  WNDIndigoQuad face;
  WNDIndigoQuad shoulder;
  WNDIndigoQuad joystick;
} WNDIndigoGameController; // 0x80 bytes (largest union member)

typedef union {
  WNDIndigoTouch          touch;
  WNDIndigoWheel          wheel;
  WNDIndigoButton         button;
  WNDIndigoAccelerometer  accelerometer;
  WNDIndigoForce          force;
  WNDIndigoGameController  gameController;
} WNDIndigoEvent; // 0x80

typedef struct {
  unsigned int       field1;    // 0x20  eventKind: 0x0b for touch, 2 for button
  unsigned long long timestamp; // 0x24  mach_absolute_time()
  unsigned int       field3;    // 0x2c  zeroed
  WNDIndigoEvent     event;     // 0x30
} WNDIndigoPayload; // 0x90

typedef struct {
  WNDMachMessageHeader header;    // 0x00
  unsigned int         innerSize; // 0x18  always 0xA0 from Apple, 0x90 in our touch builder
  unsigned char        eventType; // 0x1c  1=button 2=touch
  WNDIndigoPayload     payload;   // 0x20
} WNDIndigoMessage; // 0xB0

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
