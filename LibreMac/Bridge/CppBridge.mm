// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

#import "CppBridge.h"

// All bridge implementation lives in BridgeNative; this .mm exists so
// Xcode can register the Bridge directory as Obj-C++ and the linker
// pulls in libBridgeNative.a.
