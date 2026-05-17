// ================================================================
// q_midi_device.cpp
// Description : Local replacement for vendor/q/q_io/src/midi_device.cpp
// ================================================================
//
// Replicated from Q (MIT-licensed, copyright Cycfi Research) with two
// local fixes to midi_device::list(). This file is built instead of
// the vendor copy to avoid duplicate definitions of
// midi_device::list / portmidi_init.
//
// Why this copy exists:
//   1. Upstream list() kept a static accumulator and never cleared it.
//      Repeated calls accumulated duplicates, and unplugged devices
//      stayed visible as stale entries.
//   2. Upstream midi_device borrowed impl by reference into a shared
//      backing buffer (impl const& _impl), so a later list() call
//      invalidated every prior midi_device. AddressSanitizer flagged
//      this as heap-buffer-overflow inside _M_realloc_append during
//      parallel Tasty test runs.
//
// What changed:
// midi_device now owns its impl by value via the local shadow header
// tinysynth/q_io/midi_device.hpp; returned objects are fully
// self-contained and survive any number of subsequent list() calls.
// The static accumulator is therefore gone — each list() builds a
// fresh local vector. The mutex around enumeration stays as
// defense-in-depth: PortMIDI's Pm_CountDevices / Pm_GetDeviceInfo
// touch global backend state and are not documented as reentrant.
//
// Upstream copyright preserved verbatim:

/*=============================================================================
   Copyright (c) 2014-2024 Joel de Guzman. All rights reserved.

   Distributed under the MIT License [ https://opensource.org/licenses/MIT ]
=============================================================================*/
#include <q_io/midi_device.hpp>
#include <infra/assert.hpp>
#include <portmidi.h>
#include <mutex>
#include <string>

namespace cycfi::q
{
   // midi_device::impl is now defined in the shadow header
   // tinysynth/q_io/midi_device.hpp because midi_device stores _impl
   // by value (rather than by reference), which requires the impl
   // layout to be visible at class-definition time. See that header
   // for the rationale.

   uint32_t midi_device::id() const
   {
      return _impl._id;
   }

   std::string midi_device::name() const
   {
      return _impl._name;
   }

   std::size_t midi_device::num_inputs() const
   {
      return _impl._num_inputs;
   }

   std::size_t midi_device::num_outputs() const
   {
      return _impl._num_outputs;
   }

   namespace detail
   {
      struct port_midi_init
      {
         port_midi_init()
         {
            auto err = Pm_Initialize();
            CYCFI_ASSERT(err == pmNoError, "Error! Failed to initialize PortMIDI.");
         }

         ~port_midi_init()
         {
            auto err = Pm_Terminate();
            CYCFI_ASSERT(err == pmNoError, "Error! Failed to terminate PortMIDI.");
         }
      };

      port_midi_init const& portmidi_init()
      {
         // This will initialize PortMIDI on first call.
         static detail::port_midi_init init_;
         return init_;
      }
   }

   std::vector<midi_device> midi_device::list()
   {
      // Make sure we're initialized
      detail::portmidi_init();

      // Defense-in-depth: PortMIDI's Pm_CountDevices /
      // Pm_GetDeviceInfo touch global backend state and are not
      // documented as reentrant. Two threads calling list()
      // simultaneously also previously raced the static accumulator
      // used to back midi_device's `impl const&` (see commit
      // history); the accumulator is gone now that midi_device owns
      // impl by value, but the PortMIDI re-entry risk remains.
      static std::mutex list_mutex;
      std::lock_guard<std::mutex> guard(list_mutex);

      int num_devices = Pm_CountDevices();
      if (num_devices < 0)
         return {};

      std::vector<midi_device> result;
      result.reserve(static_cast<std::size_t>(num_devices));
      for (auto i = 0; i < num_devices; ++i)
      {
         PmDeviceInfo const* info = Pm_GetDeviceInfo(i);
         midi_device::impl impl;
         impl._id = static_cast<std::uint32_t>(i);
         impl._name = info->name;
         if (info->input || info->output)
         {
            impl._num_inputs = static_cast<std::size_t>(info->input);
            impl._num_outputs = static_cast<std::size_t>(info->output);
            result.push_back(midi_device(impl));
         }
      }
      return result;
   }
}
