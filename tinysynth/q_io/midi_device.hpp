// ================================================================
// q_io/midi_device.hpp (local shadow header)
// ================================================================
//
// Why this shadow exists:
// vendor/q/q_io/include/q_io/midi_device.hpp declares
//   midi_device { impl const& _impl; }
// which means every midi_device returned from list() borrows storage
// owned by an enumeration-call-scoped buffer. AddressSanitizer flagged
// the resulting use-after-free pattern when parallel Tasty workers
// each called list() and then used midi_device objects across the
// boundary of a subsequent list() call: heap-buffer-overflow inside
// _M_realloc_append, allocation site in the prior list().
//
// What changed here:
// store impl by value. The impl struct is now defined in the class
// (it must be, because _impl is no longer a reference), so the cpp
// implementation no longer redeclares it. midi_device is now fully
// self-contained: list() can return objects whose lifetimes are
// independent of any shared backing store. The static accumulator in
// q_midi_device.cpp is therefore gone; the mutex around enumeration
// stays only as defense-in-depth for PortMIDI's global state.
//
// Why this shadow rather than patching the submodule:
// keeps vendor/q clean for future submodule updates. Both package.yaml
// (cxx-sources) and CMakeLists.txt put `tinysynth` ahead of
// `vendor/q/q_io/include` on the include path, so this header wins
// for every consumer in this repo. The include guard matches Q's so
// the vendor header becomes a no-op if accidentally found first.
//
// Drop this file when Q upstreams the by-value fix.
//
// Upstream copyright preserved verbatim:

/*=============================================================================
   Copyright (c) 2014-2024 Joel de Guzman. All rights reserved.

   Distributed under the MIT License [ https://opensource.org/licenses/MIT ]
=============================================================================*/
#if !defined(CYCFI_Q_MIDI_DEVICE_HPP_DECEMBER_10_2018)
#define CYCFI_Q_MIDI_DEVICE_HPP_DECEMBER_10_2018

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace cycfi::q
{
   ////////////////////////////////////////////////////////////////////////////
   class midi_device
   {
   public:

      using device_list = std::vector<midi_device>;

      static device_list         list();
      std::uint32_t              id() const;
      std::string                name() const;
      std::size_t                num_inputs() const;
      std::size_t                num_outputs() const;

   private:

      struct impl
      {
         std::uint32_t  _id;
         std::string    _name;
         std::size_t    _num_inputs;
         std::size_t    _num_outputs;
      };

      midi_device(impl const& impl_)
       : _impl(impl_)
      {}

      impl                       _impl;
   };
}

#endif
