// ================================================================
// q_midi_device.cpp
// Description : Local replacement for vendor/q/q_io/src/midi_device.cpp
// ================================================================
//
// Replicated from Q (MIT-licensed, copyright Cycfi Research) with
// one targeted fix; see PATCH note below. Built in place of the
// vendor copy, which is dropped from cxx-sources / CMakeLists.txt
// to avoid an ODR collision on midi_device::list / portmidi_init.
//
// When upstream Q gets the same fix (or this codebase monorepo's
// the vendor split), this file can go away in favour of the upstream
// implementation.
//
// PATCH (vs. upstream): midi_device::list() previously used a static
// std::vector<midi_device::impl> as an accumulator and never cleared
// it, so:
//   * Each call appended every device again -> duplicates grew
//     without bound.
//   * Devices unplugged between calls stuck around in the vector
//     forever (stale entries reported as live).
// Both feed back into rt_midi_demo's id-matching probe, where a
// stale ghost would pass the input-device check, get handed to
// q::midi_input_stream(device), trigger Pm_OpenInput failure on the
// gone hardware, and the resulting _impl == nullptr would later
// crash in the (also-patched) ~midi_input_stream Pm_Close call.
// Switching to a local std::vector clears that whole chain.
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

      int num_devices = Pm_CountDevices();
      if (num_devices < 0)
         return {};

      // PATCH: local (non-static) accumulator. The upstream version
      // declared this `static` and never cleared it; see the file
      // header for why that's a load-bearing bug for our use.
      std::vector<midi_device::impl> devices;
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
