// ================================================================
// q_midi_device.cpp
// Description : Local replacement for vendor/q/q_io/src/midi_device.cpp
// ================================================================
//
// Replicated from Q (MIT-licensed, copyright Cycfi Research) with one
// local fix to midi_device::list(). This file is built instead of the
// vendor copy to avoid duplicate definitions of midi_device::list /
// portmidi_init.
//
// Why this copy exists:
// upstream list() kept a static accumulator and never cleared it.
// Repeated calls accumulated duplicates, and unplugged devices stayed
// visible as stale entries. The live-MIDI demo chooses devices by id,
// so it needs each list() call to describe the current PortMIDI view.
//
// What changed:
// keep the backing vector static, but clear() and repopulate it on
// every call. The vector must stay static because midi_device stores
// `impl const& _impl`; a local backing vector would be destroyed on
// return and every midi_device would dangle.
//
// Contract:
// use the returned midi_device objects before the next list() call.
// A later list() invalidates earlier objects by clearing and
// repopulating the shared backing vector. The cleaner long-term fix is
// to patch Q's header so midi_device owns impl by value; that is
// deferred because it affects every Q consumer.
//
// Upstream copyright preserved verbatim:

/*=============================================================================
   Copyright (c) 2014-2024 Joel de Guzman. All rights reserved.

   Distributed under the MIT License [ https://opensource.org/licenses/MIT ]
=============================================================================*/
#include <q_io/midi_device.hpp>
#include <infra/assert.hpp>
#include <portmidi.h>
#include <string>

namespace cycfi::q
{
   struct midi_device::impl
   {
      uint32_t       _id;
      std::string    _name;
      std::size_t    _num_inputs;
      std::size_t    _num_outputs;
   };

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
            CYCFI_ASSERT(err == pmNoError, "Error! Failed to initialize PortAudio.");
         }

         ~port_midi_init()
         {
            auto err = Pm_Terminate();
            CYCFI_ASSERT(err == pmNoError, "Error! Failed to terminate PortAudio.");
         }
      };

      port_midi_init const& portmidi_init()
      {
         // This will initialize port audio on first call
         static detail::port_midi_init init_;
         return init_;
      }
   }

   std::vector<midi_device> midi_device::list()
   {
      // Make sure we're initialized
      detail::portmidi_init();

      // PATCH: keep the accumulator static because midi_device stores
      // `impl const&`, but clear it on every call so stale / duplicate
      // entries cannot survive from an earlier enumeration.
      static std::vector<midi_device::impl> devices;
      devices.clear();

      int num_devices = Pm_CountDevices();
      if (num_devices < 0)
         return {};

      devices.reserve(static_cast<std::size_t>(num_devices));
      PmDeviceInfo const* info;
      for (auto i = 0; i < num_devices; ++i)
      {
         info = Pm_GetDeviceInfo(i);
         midi_device::impl impl;
         impl._id = i;
         impl._name = info->name;
         if (info->input || info->output)
         {
            impl._num_inputs = info->input;
            impl._num_outputs = info->output;
            devices.push_back(impl);
         }
      }

      std::vector<midi_device> result;
      result.reserve(devices.size());
      for (auto const& impl : devices)
         result.push_back(impl);
      return result;
   }
}
