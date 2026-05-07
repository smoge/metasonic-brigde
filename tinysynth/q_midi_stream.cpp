// ================================================================
// q_midi_stream.cpp
// Description : Local replacement for vendor/q/q_io/src/midi_stream.cpp
// ================================================================
//
// Replicated from Q (MIT-licensed, copyright Cycfi Research) with
// one targeted fix; see PATCH note below. Built in place of the
// vendor copy, which is dropped from cxx-sources / CMakeLists.txt
// to avoid an ODR collision on midi_input_stream::* and the
// detail::default_device_id / input_stream_init internals.
//
// PATCH (vs. upstream): ~midi_input_stream now guards _impl before
// calling Pm_Close. The upstream version called
// Pm_Close(reinterpret_cast<PortMidiStream*>(_impl)) unconditionally,
// which on hosts where Pm_OpenInput failed (no /dev/snd/seq access,
// busy device, ghost device left over from a prior list() call --
// see the patch in q_midi_device.cpp) crashes with a segfault on
// some PortMIDI builds. The guard is one line and matches the same
// _impl-null check Q already does in next() at line ~50.
//
// When upstream Q lands the same guard, this file can go away in
// favour of the upstream implementation.
//
// Upstream copyright preserved verbatim:

/*=============================================================================
   Copyright (c) 2014-2024 Joel de Guzman. All rights reserved.

   Distributed under the MIT License [ https://opensource.org/licenses/MIT ]
=============================================================================*/
#include <q_io/midi_stream.hpp>
#include <portmidi.h>

namespace cycfi::q
{
   namespace detail
   {
      struct port_midi_init;
      port_midi_init const& portmidi_init();

      int default_device_id = 0;

      void input_stream_init(midi_input_stream::impl*& _impl, int id)
      {
         // Make sure we're initialized
         detail::portmidi_init();
         auto err = Pm_OpenInput(
            reinterpret_cast<PortMidiStream**>(&_impl)
         , id, nullptr, 256, nullptr, nullptr);

         if (err != pmNoError)
            _impl = nullptr;
      }
   }

   midi_input_stream::midi_input_stream()
   {
      detail::input_stream_init(_impl, detail::default_device_id);
   }

   midi_input_stream::midi_input_stream(midi_device const& device)
   {
      detail::input_stream_init(_impl, device.id());
   }

   midi_input_stream::~midi_input_stream()
   {
      // PATCH: only Pm_Close on a successfully-opened stream. See file
      // header for why this matters with the (now-fixed) Q list() bug.
      if (_impl)
         Pm_Close(reinterpret_cast<PortMidiStream*>(_impl));
   }

   bool midi_input_stream::next(event& ev)
   {
      if (_impl)
      {
         PmEvent event;
         auto stream = reinterpret_cast<PortMidiStream*>(_impl);
         if (Pm_Read(stream, &event, 1))
         {
            ev.msg = { std::uint32_t(event.message) };
            ev.time = event.timestamp;
            return true;
         }
      }
      return false;
   }

   void midi_input_stream::set_default_device(int id)
   {
      detail::default_device_id = id;
   }
}
