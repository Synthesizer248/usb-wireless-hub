/*++

Module Name:

    device.h

Abstract:

    This file contains the device definitions.

Environment:

    Kernel-mode Driver Framework

--*/

#include "public.h"
#include <vhf.h>

EXTERN_C_START

//
// The device context performs the same job as
// a WDM device extension in the driver frameworks
//
typedef struct _DEVICE_CONTEXT
{
    WDFWAITLOCK VirtualDeviceLock;
    LIST_ENTRY VirtualDevices;

} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

typedef struct _USBHUB_VIRTUAL_HID_DEVICE {
    LIST_ENTRY Link;
    UCHAR DeviceId[USBHUB_HID_DEVICE_ID_LENGTH];
    VHFHANDLE VhfHandle;
    PUCHAR ReportDescriptor;
    USHORT ReportDescriptorLength;
} USBHUB_VIRTUAL_HID_DEVICE, *PUSBHUB_VIRTUAL_HID_DEVICE;

//
// This macro will generate an inline function called DeviceGetContext
// which will be used to get a pointer to the device context memory
// in a type safe manner.
//
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, DeviceGetContext)

//
// Function to initialize the device and its callbacks
//
NTSTATUS
UsbHubVhfKeyboardCreateDevice(
    _Inout_ PWDFDEVICE_INIT DeviceInit
    );

EVT_WDF_OBJECT_CONTEXT_CLEANUP UsbHubVhfKeyboardEvtDeviceContextCleanup;

EXTERN_C_END
