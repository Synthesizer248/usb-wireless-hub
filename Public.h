/*++

Module Name:

    public.h

Abstract:

    This module contains the common declarations shared by driver
    and user applications.

Environment:

    user and kernel

--*/

//
// Define an Interface Guid so that apps can find the device and talk to it.
//

DEFINE_GUID (GUID_DEVINTERFACE_UsbHubVhfKeyboard,
    0x8eb5148c,0x0bdb,0x4fad,0xbe,0xfa,0xb5,0xd2,0x51,0xd0,0x92,0x2a);
// {8eb5148c-0bdb-4fad-befa-b5d251d0922a} — distinct from the keyboard prototype.

// The bridge can create multiple runtime VHF children, one per HID interface.
#define IOCTL_USBHUB_VHF_CREATE_HID_DEVICE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)
#define IOCTL_USBHUB_VHF_REMOVE_HID_DEVICE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_WRITE_DATA)
#define IOCTL_USBHUB_VHF_SUBMIT_HID_REPORT \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_WRITE_DATA)

#define USBHUB_HID_DEVICE_ID_LENGTH 16
#define USBHUB_HID_MAX_DESCRIPTOR_LENGTH 4096
#define USBHUB_HID_MAX_REPORT_LENGTH 4096

// Wire layout is fixed and shared with the user-mode receiver.
// Create: DeviceId[16], DescriptorLength, VendorId, ProductId, Version, Descriptor[]
typedef struct _USBHUB_HID_CREATE_INPUT {
    UCHAR DeviceId[USBHUB_HID_DEVICE_ID_LENGTH];
    USHORT DescriptorLength;
    USHORT VendorId;
    USHORT ProductId;
    USHORT Version;
    UCHAR Descriptor[1];
} USBHUB_HID_CREATE_INPUT, *PUSBHUB_HID_CREATE_INPUT;

// Remove: DeviceId[16]
typedef struct _USBHUB_HID_REMOVE_INPUT {
    UCHAR DeviceId[USBHUB_HID_DEVICE_ID_LENGTH];
} USBHUB_HID_REMOVE_INPUT, *PUSBHUB_HID_REMOVE_INPUT;

// Submit: DeviceId[16], ReportLength, ReportId, Reserved, Report[]
typedef struct _USBHUB_HID_REPORT_INPUT {
    UCHAR DeviceId[USBHUB_HID_DEVICE_ID_LENGTH];
    USHORT ReportLength;
    UCHAR ReportId;
    UCHAR Reserved;
    UCHAR Report[1];
} USBHUB_HID_REPORT_INPUT, *PUSBHUB_HID_REPORT_INPUT;
