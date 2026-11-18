# Third-Party Notices

Dieses Projekt enthält keine Fremdcode-Dependencies (kein Swift-Package
verlinkt externen Code). Es enthält aber einen **portierten Algorithmus**
aus einem BSD-lizenzierten Fremdprojekt, dessen Lizenzbedingungen bei
Weitergabe von Quellcode das Beibehalten von Copyright-Vermerk,
Lizenzbedingungen und Haftungsausschluss verlangen (siehe unten). Dieser
Hinweis erfüllt genau das.

## SickToolbox (`SickPLSMessage::_computeCRC`)

**Betroffene Dateien in diesem Projekt:** `Sources/SickPLSCore/CRC16.swift`
(Algorithmus) und `Sources/SickPLSCore/FrameConstants.swift` (Konstanten
`headerLength`, `payloadMaxLength`, `trailerLength`,
`crcGeneratorPolynomial`).

**Herkunft:** Bit-für-Bit-Port von `SickPLSMessage::_computeCRC` aus dem
SickToolbox-Referenzcode. Bezogen über den öffentlichen ROS-Port
<https://github.com/asr-ros/asr_mild_base_laserscanner/blob/master/src/SickPLSMessage.cc>
(Datei- und Lizenzkopf dort wörtlich zitiert), gegengeprüft als
bit-identisch zu `SickLMS2xxMessage::_computeCRC` in der offiziellen,
weiterhin gepflegten Quelle
<https://github.com/ros-drivers/sicktoolbox/blob/catkin/c%2B%2B/drivers/lms2xx/sicklms2xx/SickLMS2xxMessage.cc>
(dortige `COPYING`-Datei: <https://github.com/ros-drivers/sicktoolbox/blob/catkin/COPYING>).

**Lizenz:** BSD (3-Klausel), wörtlicher Text unten unverändert aus der
`COPYING`-Datei des offiziellen `ros-drivers/sicktoolbox`-Repositories
übernommen.

```
--------------------------------------------------------------------
--------------------------------------------------------------------
The Sick LIDAR Matlab/C++ Toolbox (BSD) License
--------------------------------------------------------------------

The Sick LIDAR Matlab/C++ Toolbox
Copyright (c) 2008, Jason C. Derenick and Thomas H. Miller
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

    * Redistributions of source code must retain the above
      copyright notice, this list of conditions and the following
      disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials
      provided with the distribution.
    * Neither the name(s) of the copyright holders nor the names
      of its contributors may be used to endorse or promote products
      derived from this software without specific prior written
      permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--------------------------------------------------------------------
```

## Lizenz dieses Projekts

Die eigenen Beiträge dieses Projekts stehen seit 18.11.2026 unter der GNU General
Public License v3 (Owner-Entscheidung, wie FIRSTofFIFTH; siehe [`LICENSE`](LICENSE);
vorher MIT). Dieses Dokument regelt davon getrennt ausschließlich die
Weitergabebedingungen des oben genannten Fremdalgorithmus: Der CRC16-Port aus
SickToolbox bleibt unter seiner eigenen BSD-Lizenz. Die BSD-3-Klausel-Lizenz ist
mit der GPLv3 vereinbar; ihr Copyright-Vermerk, ihre Bedingungen und ihr
Haftungsausschluss bleiben bei jeder Weitergabe erhalten (oben wörtlich).
