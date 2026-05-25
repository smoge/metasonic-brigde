

MIDIClient.init;
MIDIIn.connectAll;

(
~m = MIDIOut.newByName("Midi Through", "Midi Through Port-0");
~m.latency = 0;

~m.control(0, 74, 90); // cutoff -> /v0/lpf/0
~m.control(0, 71, 40); // q      -> /v0/lpf/1
~m.control(0, 7, 30);  // level  -> /v0/gain/0
)

~m.control(0, 74, 64);


//If MIDIOut.newByName fails, run this in sclang to see exact destination names:

MIDIClient.init;
MIDIClient.destinations.do { |d, i| [i, d.device, d.name, d.uid].postln };

MIDI devices reported by Q / PortMIDI:
  id=0  inputs=0  outputs=1  no input  name="Midi Through Port-0"
  id=1  inputs=1  outputs=0  input  name="Midi Through Port-0"
  id=2  inputs=0  outputs=1  no input  name="in0"
  id=3  inputs=0  outputs=1  no input  name="in1"
  id=4  inputs=0  outputs=1  no input  name="in2"
  id=5  inputs=1  outputs=0  input  name="out0"