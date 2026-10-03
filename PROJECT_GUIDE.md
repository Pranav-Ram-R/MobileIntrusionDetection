# Mobile Intrusion Detection: Complete Project Guide

A full explanation of the project for someone coming from Python and C++. It covers what the system does, how the pieces connect, how MATLAB code becomes an Android app, a MATLAB/Simulink crash course, and a walkthrough of every file.

**Contents**

1. [What the project does](#1-what-the-project-does)
2. [Block diagrams](#2-block-diagrams)
3. [How it gets implemented: from .m file to phone](#3-how-it-gets-implemented-from-m-file-to-phone)
4. [MATLAB crash course for Python/C++ developers](#4-matlab-crash-course-for-pythonc-developers)
5. [Simulink crash course (think synchronous digital circuit)](#5-simulink-crash-course-think-synchronous-digital-circuit)
6. [The network protocol](#6-the-network-protocol)
7. [File-by-file walkthrough](#7-file-by-file-walkthrough)
8. [Design decisions and why](#8-design-decisions-and-why)
9. [Testing strategy](#9-testing-strategy)
10. [Limitations and things to know before the demo](#10-limitations-and-things-to-know-before-the-demo)
11. [How to modify things](#11-how-to-modify-things)
12. [Glossary](#12-glossary)

---

## 1. What the project does

Two phones. One sits in a drawer as a **Security Node**. The other is in your hand as a **Monitoring Console**. Both run the **same app**, and a button on screen picks the role.

| Assignment requirement | Where it is implemented |
|---|---|
| 1. Node detects a light increase or movement while ARMED | `node_step.m` (light, tilt and gyro detectors with debouncing) |
| 2. On intrusion, node connects to console over TCP/UDP | UDP Send / UDP Receive blocks, packets built in `node_step.m` |
| 2a. Audible recorded message on the console | `audio_step.m` plays `alert_message.wav` (embedded at build time) |
| 2b. GPS of the node | Location Sensor block, sent in every status packet |
| 2c. Timestamped breach log | Node stamps the breach with its clock (`wall_clock.m`), console decodes it (`epoch_to_civil.m`) and keeps the last 5 |
| 3a. Console triggers a siren + LED flash on the node | `CMD_SIREN_ON`, siren synthesised in `audio_step.m`, LED strobe via the ToApp block + `patch_android_torch.m` |
| 3b. Console toggles ARMED / DISARMED remotely | `CMD_ARM` / `CMD_DISARM` in `console_step.m` and `node_step.m` |
| 4. Both phones interchangeable | One model, role chosen at runtime by the "Console mode" button |

---

## 2. Block diagrams

### 2.1 System view: two phones on the same Wi-Fi

```
          PHONE A  (role = Security Node)                       PHONE B  (role = Monitoring Console)
 +------------------------------------------------+     +------------------------------------------------+
 |  Light     Orientation   Gyroscope   Location  |     |   [Arm/Disarm]   [Siren]   [Acknowledge]       |
 |  sensor    sensor        sensor      (GPS)     |     |        buttons on the touch screen             |
 |     \          |             |         /       |     |                     |                          |
 |      v         v             v        v        |     |                     v                          |
 |    +--------------------------------------+    |     |    +--------------------------------------+    |
 |    |            SecurityCore              |    |     |    |            SecurityCore              |    |
 |    |   node logic ACTIVE                  |=======STATUS=====>   console logic ACTIVE            |    |
 |    |   console logic held in reset        |<=====COMMANDS======  node logic held in reset        |    |
 |    +--------------------------------------+    | UDP |    +--------------------------------------+    |
 |       |                  |                     |25000|       |                       |                |
 |       v                  v                     |     |       v                       v                |
 |   Speaker: SIREN    Camera LED: STROBE         |     |   Speaker: VOICE ALERT    Screen: state,       |
 |                                                |     |   (recorded message)      breach time, GPS,    |
 |                                                |     |                           breach log           |
 +------------------------------------------------+     +------------------------------------------------+
```

Status packets flow A to B every 0.5 s and immediately on any event. Command packets flow B to A every 0.5 s and immediately when you tap a button. Swap the role button on both phones and the arrows reverse.

### 2.2 Inside one app (`ids_android_app.slx`)

```
   ANDROID INPUT BLOCKS            ADAPTERS                CORE                     ANDROID OUTPUT BLOCKS
 +---------------------+
 | Button "Console     |--> to double --> +1 ----> role  (1 = node, 2 = console)
 | mode (role)"        |                          |
 +---------------------+                          |
 | Light Sensor        |--> to double ----------> lux
 | Orientation         |--> to double ----------> ori  [pitch roll azimuth]
 | Gyroscope           |--> (mux) to double ----> gyro [wx wy wz]          +----------------+
 | Location Sensor     |--> (mux) to double ----> gps  [lat lon alt]       |                |--tx[16]--+--> Enabled subsystem
 | WallClock (MATLAB   |----------------------->  epoch                    |  SecurityCore  |--txEn----+    "Transmit"
 |  Function: time())  |                          |                        |                |                (UDP Send inside)
 | UDP Receive         |--Data[16]-------------> rx                        |   (identical   |--audio[4410x2]--> Audio Playback
 |                     |--Size--> to double ---> rxSize                    |   in the test  |--torch---------> ToApp "TorchControl"
 | Button Arm/Disarm   |--> to double ----------> btnArm                   |   harness)     |--uiNode--------> Data Display
 | Button Siren        |--> to double ----------> btnSiren                 |                |--uiStatus------> Data Display
 | Button Acknowledge  |--> to double ----------> btnAck                   |                |--uiBreach------> Data Display
 +---------------------+                                                   |                |--uiLive--------> Data Display
                                                                           |                |--uiLog---------> Data Display
                                                                           +----------------+
```

Everything runs once every **0.1 s** (10 Hz). The "to double" blocks exist because each Android block outputs its own type (single, boolean, uint16) and the core logic is written for `double`.

### 2.3 Inside `SecurityCore`

```
                 +-----------------------------------------------+
  role --------->|                                               |---> tx[16]
  lux  --------->|            Controller                         |---> txEn
  ori  --------->|      (MATLAB Function block)                  |---> torch (int32)
  gyro --------->|                                               |
  gps  --------->|   persistent N  (node state struct)           |---> uiNode, uiStatus, uiBreach, uiLive, uiLog
  epoch--------->|   persistent C  (console state struct)        |
  rx   --------->|                                               |      sirenOn     alertOn
  rxSize-------->|   N = node_step(N, isNode, ...)               |---------+-----------+
  btnArm-------->|   C = console_step(C, ~isNode, ...)           |         |           |
  btnSiren------>|   pick tx from whichever role is active       |         v           v
  btnAck ------->|                                               |   +-----------------------+
                 +-----------------------------------------------+   |     AudioEngine       |
                                                                     | (MATLAB Function)     |---> audio [4410 x 2 int16]
                                                                     | persistent A          |
                                                                     | siren synth + message |
                                                                     +-----------------------+
```

### 2.4 Security Node state machine

```
                        ARM command                       5 s exit delay over,
      +-----------+  ------------------->  +---------+   baseline learnt          +---------+
      | DISARMED  |                        | ARMING  | -------------------------> |  ARMED  |
      |    (0)    |                        |   (1)   |                            |   (2)   |
      +-----------+                        +---------+                            +---------+
         ^     ^                               ^                                       |
         |     |                               |  ARM command (re-arm)                 | light jump  OR
         |     |                               +--------------------+                  | tilt > 10 deg OR
         |     |                                                    |                  | gyro > 0.6 rad/s
         |     |          DISARM command                       +---------+             | (debounced)
         |     +--------------------------------------------- |  ALARM  | <-----------+
         |                                                     |   (3)   |   breach #, time, GPS, cause
         |            DISARM command from ANY state            +---------+   are latched here
         +-----------------------------------------------------------

   Independent of the states above:  SIREN_ON / SIREN_OFF commands switch the siren and LED.
   DISARM also switches the siren off.
```

### 2.5 What happens during a breach (time runs downward)

```
  Phone A (node)                                Network                     Phone B (console)
  --------------                                -------                     -----------------
  t=0.0  drawer opens, lux 0.5 -> 80
  t=0.1  lux above threshold (count 1)
  t=0.2  count 2
  t=0.3  count 3 -> ALARM, breach #1 latched
         status packet sent IMMEDIATELY  ----------- UDP --------------->  t=0.4  packet valid, state=ALARM,
                                                                                  breach #1 > acked #0
                                                                                  -> alert ON, voice message loops
                                                                                  -> breach time decoded and logged
         heartbeat every 0.5 s  ---------------------------------------->        (keeps link alive, live GPS)

                                                                           user taps [Siren]
                                          <---------- UDP --------------   cmdSeq=2, code=SIREN_ON
  seq 2 is new -> siren ON, LED strobes                                   (re-sent every 0.5 s until A confirms)
  next status carries lastCmdSeq=2 ----------------------------------->   confirmed, stops treating it as pending

                                                                           user taps [Acknowledge]
                                                                           voice alert stops locally

                                                                           user taps [Arm/Disarm]
                                          <-----------------------------   cmdSeq=3, code=DISARM
  DISARMED, siren OFF, LED OFF
```

### 2.6 The desktop test harness (`ids_sim_harness.slx`)

```
  ids_scenario.m (scripted sensors + button taps)
        |                                   |
        v                                   v
  +--------------+    tx, txEn      +----------------+     tx, txEn    +--------------+
  |   Phone_A    |----------------->|  WiFi_Network  |<----------------|   Phone_B    |
  | SecurityCore |                  | drops 20% of   |                 | SecurityCore |
  |              |<---- Unit Delay -| datagrams      |- Unit Delay --->|              |
  +--------------+     (0.1 s)      +----------------+    (0.1 s)      +--------------+
        |                                                                    |
        +----------------> To Workspace logs <-------------------------------+
                                   |
                                   v
                    run_harness_test.m: 13 PASS/FAIL checks + harness_timeline.png
```

The two `SecurityCore` blocks are built by the **same function** as the one inside the Android app, so the logic you test on the PC is the logic that ships to the phone.

---

## 3. How it gets implemented: from .m file to phone

```
  ids_params.m, node_step.m, console_step.m, audio_step.m, ...      plain MATLAB functions (testable alone)
                         |
                         |  called from
                         v
  Controller + AudioEngine  (MATLAB Function blocks)                 code lives in the block, calls the .m files
                         |
                         |  wrapped by build_security_core.m
                         v
  SecurityCore subsystem
                         |
                         |  build_android_model.m surrounds it with Android sensor/UI/network blocks
                         v
  ids_android_app.slx    (a Simulink model)
                         |
                         |  Hardware tab > Build   (code generation)
                         v
  C source code: ids_android_app_step() runs every 0.1 s, plus init/terminate functions
                         |
                         |  Android NDK compiler (clang)
                         v
  native library (.so)  +  generated Java Activity (UI widgets, sensors, sockets)
                         |
                         |  patch_android_torch.m inserts TorchControl() into the Java Activity
                         v
  Gradle build  ->  APK  ->  installed on the phone over USB
```

**Analogy you already know.** This is the same idea as Vitis HLS. You write a restricted subset of a high-level language, a tool translates it into a lower-level form (C here, RTL there), and the restrictions exist for the same reason: the generated code must have fixed sizes and fixed types known at compile time. That is why the logic files avoid growing arrays, avoid changing a variable's type, and pre-size everything.

What runs where at runtime on the phone:

- The **C code** (from your MATLAB logic) runs on a background thread, called every 0.1 s.
- The **Java Activity** owns the screen, the sensors, the sockets and the speaker. The support package's generated glue passes data between Java and C.
- The **ToApp** block is the one place where C calls a Java method that you wrote yourself (the LED control).

---

## 4. MATLAB crash course for Python/C++ developers

### 4.1 The big differences, in one table

| Concept | Python | C++ | MATLAB |
|---|---|---|---|
| Indexing | `x[0]` first | `x[0]` first | `x(1)` first. **1-based**, round brackets |
| Last element | `x[-1]` | `x[n-1]` | `x(end)` |
| Slice | `x[0:16]` (end exclusive) | loop | `x(1:16)` (**end inclusive**) |
| Range | `range(1, 11)` | `for(i=1;i<=10;i++)` | `1:10` (inclusive) |
| Not equal | `!=` | `!=` | `~=` |
| Logical not | `not a` | `!a` | `~a` |
| And / or (short-circuit) | `and`, `or` | `&&`, `\|\|` | `&&`, `\|\|` |
| Comment | `# ...` | `// ...` | `% ...` |
| Print suppress | n/a | n/a | end a line with `;` (otherwise MATLAB prints the result) |
| String | `'abc'` or `"abc"` | `"abc"` | `'abc'` (char array) or `"abc"` (string object) |
| String concat | `a + b` | `a + b` | `[a b]` for char arrays |
| Lambda | `lambda x: x+1` | `[](int x){return x+1;}` | `@(x) x+1` |
| List of anything | `[1, 'a', obj]` | `std::vector<std::any>` | cell array `{1, 'a', obj}`, access with `c{1}` |
| Dict | `{'k': v}` | `std::map` | `containers.Map` or a struct |
| Struct / record | dataclass, dict | `struct` | `S.field = value` (fields created on assignment) |
| Discard a return value | `_, b = f()` | `std::tie(std::ignore, b)` | `[~, b] = f()` |
| Default args | `def f(a, b=2)` | `void f(int a, int b=2)` | check `nargin` (number of args passed) |
| Keyword args | `f(a, name=1)` | n/a | `f(a, 'Name', 1)` + `inputParser` |
| Static local variable | module global | `static int x;` | `persistent x` |
| Exceptions | `try/except` | `try/catch` | `try ... catch err ... end` |
| Raise | `raise ValueError(msg)` | `throw` | `error('id:x', 'msg %d', v)` |
| Block end | indentation | `}` | `end` |
| Element-wise multiply | `a * b` (NumPy) | loop | `a .* b` (`*` is **matrix** multiply) |
| Integer cast overflow | Python ints never overflow | **wraps around** | **saturates**: `int16(40000)` is `32767` |

### 4.2 Files and functions

- **One file = one public function, and the file name must equal the function name.** `node_step.m` must start with `function ... = node_step(...)`. MATLAB finds functions by file name on the *path*, the way Python finds modules on `sys.path`.
- Extra functions below the first one in a file are **local functions**, visible only inside that file (like `static` functions in a C file). `node_step.m` has a local `start_arming`.
- A function declares its outputs on the left:

```matlab
function [S, tx, txEn, torch, ui] = node_step(S, active, lux, ori, gyro, gps, epoch, rx, rxSize, P)
```

That is the MATLAB way of writing the Python `def node_step(S, active, ...): ... return S, tx, txEn, torch, ui`. Multiple return values are native.

### 4.3 Value semantics: why every function returns the state

MATLAB passes arrays and structs **by value** (internally copy-on-write, so it is cheap until you modify). This is like passing a C++ struct by value, **not** like Python where a dict is passed by reference.

So this does nothing to the caller's `S`:

```matlab
function bump(S)
    S.count = S.count + 1;     % modifies a local copy only
end
```

That is why every step function in this project has the shape `S = f(S, inputs...)`. It is a pure function: old state in, new state out. This turns out to be a great design for testing (section 9).

### 4.4 `persistent`: state that survives between calls

```matlab
persistent N C
if isempty(N)            % first call: persistent vars start as [] (empty)
    N = node_init();
    C = console_init(P.logLen);
end
```

Same as a C++ `static` local variable with a lazy init:

```cpp
static NodeState* N = nullptr;
if (!N) N = new NodeState(node_init());
```

Persistent variables live inside the MATLAB Function block, so each block instance has its own copy. That is how Phone_A and Phone_B in the harness each keep separate state.

### 4.5 Structs

```matlab
S.state = 0;          % creates field "state"
S.gps   = zeros(1,3); % 1x3 row vector of zeros
```

Behaves like a Python object you add attributes to. For code generation, the set of fields and their types must be fixed after the first definition (like a C struct). That is why `node_init.m` defines every field up front.

### 4.6 Vectors and matrices

```matlab
zeros(16, 1)       % 16x1 column vector (16 rows, 1 column)   like np.zeros((16,1))
zeros(1, 3)        % 1x3 row vector                           like np.zeros((1,3))
x(:)               % force into a column vector               like x.reshape(-1, 1)
x'                 % transpose                                 like x.T
[a, b]   or [a b]  % concatenate horizontally                 like np.hstack
[a; b]             % concatenate vertically                    like np.vstack
numel(x)           % number of elements                        like x.size
size(x)            % dimensions                                like x.shape
```

Example from `console_step.m`, a 5-entry shift register (newest first):

```matlab
C.logHms = [hms, C.logHms(1:end-1)];
```

Python equivalent: `log = [hms] + log[:-1]`. C++ equivalent: shift every element right by one, put `hms` at index 0.

### 4.7 Code generation keywords used in this project

These are what make MATLAB code compile to C. Treat them as compiler directives.

| MATLAB | Meaning | Closest C/C++ idea |
|---|---|---|
| `%#codegen` | "Check this file for C-generation compatibility" | a lint pragma |
| `coder.const(ids_params())` | Evaluate at compile time, bake results in as constants | `constexpr` |
| `coder.target('Rtw')` | True when generating embedded C for the phone | `#ifdef TARGET_ANDROID` |
| `coder.target('MATLAB')` | True when running in the normal interpreter | `#ifdef HOST` |
| `coder.ceval('time', ...)` | Emit a direct call to a C function | `extern "C"` call |
| `coder.cinclude('<time.h>')` | Add `#include <time.h>` to the generated code | `#include` |
| `coder.opaque('time_t *','NULL')` | A C value MATLAB does not understand, passed through verbatim | raw C token |
| `coder.extrinsic('host_epoch')` | During simulation only, call back into the interpreter for this function | calling Python from a C extension |
| `coder.load('file.mat','msg')` | Read a data file at compile time and embed it | `static const int16_t msg[] = {...};` in a generated header |

### 4.8 Other functions you will see

| MATLAB | Does | Python / C++ |
|---|---|---|
| `isempty(x)` | true if zero elements | `len(x) == 0` |
| `isfile(p)` / `isfolder(p)` | path checks | `os.path.isfile` |
| `fileparts(p)` | split folder / name / ext | `os.path.split`, `splitext` |
| `fullfile(a, b)` | join path | `os.path.join` |
| `sprintf` / `fprintf` | format / print | same as C |
| `strjoin(c, newline)` | join strings | `"\n".join(c)` |
| `regexp`, `regexpi` | regex (i = case-insensitive) | `re.search` |
| `mod(a, b)`, `floor(x)` | modulo, floor | `%`, `math.floor` |
| `sind`, `cosd`, `atan2d` | trig in **degrees** | `math.sin(math.radians(x))` |
| `bitand(a, b)` | bitwise AND | `a & b` |
| `any(v)`, `all(v)` | any / all true | `any()`, `all()` |
| `mfilename('fullpath')` | path of the running file | `__file__` |
| `addpath(dir)` | add to search path | `sys.path.append` |

---

## 5. Simulink crash course (think synchronous digital circuit)

You have written Verilog, so here is the most useful mental model: **a fixed-step discrete Simulink model is a synchronous circuit clocked at 1/Ts.** This project's clock is 10 Hz (`Ts = 0.1 s`).

| Simulink | Verilog / digital design analogy | C++ analogy |
|---|---|---|
| Block | module instance | function |
| Line (signal) | wire (typed, sized) | variable passed between functions |
| Subsystem | hierarchical module | function that calls other functions |
| Sample time `Ts` | clock period | period of the main loop |
| One simulation step | one clock edge | one iteration of `while(true){...; sleep(Ts);}` |
| MATLAB Function block with `persistent` | `always @(posedge clk)` block with registers | function with `static` locals |
| Unit Delay block | D flip-flop (`q <= d`) | `prev = current;` at end of loop |
| Algebraic loop | combinational loop | infinite recursion |
| Enabled Subsystem | logic gated by an enable | `if (enable) { ... }` |
| Inport / Outport | module ports | function parameters / return |
| Mux | bus concatenation `{a, b, c}` | building an array |
| Data Type Conversion | `$signed()` / width cast | `static_cast<double>()` |
| Constant block | tie-off `assign x = 5;` | literal |
| To Workspace | `$dumpvars` / waveform dump | logging to a file |
| From Workspace | testbench stimulus vectors | reading a test vector file |
| Model workspace | local parameter storage | static data in the binary |

**How the phone app executes.** Generated C looks conceptually like this:

```cpp
void app_main() {
    model_initialize();                  // runs node_init, console_init, audio_init on first step
    while (running) {
        read_sensors_and_ui();           // Light Sensor, Orientation, Gyroscope, Location, Buttons, UDP Receive
        model_step();                    // SecurityCore: Controller + AudioEngine
        write_outputs();                 // UDP Send (if txEn), Audio Playback, ToApp, Data Display
        wait_until_next_100ms_tick();
    }
}
```

**Why there are Unit Delays in the harness.** Phone_A's output `tx` feeds Phone_B's input `rx`, and Phone_B's `tx` feeds Phone_A's `rx`. Inside each core, `tx` depends on `rx` in the same step. Without a register in between, that is a combinational loop (Simulink calls it an algebraic loop). A Unit Delay breaks it, exactly like inserting a flip-flop, and it also models 0.1 s of network latency.

**Building models from code.** Instead of dragging blocks with the mouse, `build_*.m` scripts call the Simulink API. Think of it as a Python script that writes a netlist:

```matlab
new_system('mymodel');                                            % create empty model
add_block('simulink/Sources/Constant', 'mymodel/Five', 'Value', '5');   % instantiate from library
add_block('simulink/Sinks/Display',    'mymodel/Show');
add_line('mymodel', 'Five/1', 'Show/1');                          % wire output port 1 to input port 1
set_param('mymodel', 'StopTime', '10');                           % set a property
save_system('mymodel');
```

Why scripts instead of clicking: the model is reproducible, reviewable as text, and if anything goes wrong you delete the `.slx` and rebuild it in seconds.

---

## 6. The network protocol

Transport: **UDP**, port **25000**, every datagram is **16 doubles = 128 bytes**. By default packets are sent to the broadcast address `255.255.255.255`, so neither phone needs to know the other's IP.

Why UDP instead of TCP: TCP needs one side to be a server and the other a client, which breaks the symmetry required by requirement 4, and a TCP Receive block in blocking mode would stall the 10 Hz loop. UDP plus our own sequence numbers and resends gives reliable delivery without either problem.

### 6.1 Status packet (Security Node to Console), `TYPE_STATUS = 1`

| Index | Field | Notes |
|---|---|---|
| 1 | MAGIC = 7331 | rejects random traffic |
| 2 | TYPE = 1 | status |
| 3 | node state | 0 DISARMED, 1 ARMING, 2 ARMED, 3 ALARM |
| 4 | breach sequence number | increments on each breach |
| 5 | breach time | Unix epoch seconds (UTC) from the node's clock |
| 6 | cause bit mask | 1 light, 2 tilt, 4 motion |
| 7, 8 | breach lat, lon | GPS at the moment of the breach |
| 9, 10, 11 | live lat, lon, alt | latest GPS fix, useful if the phone is carried away |
| 12 | siren on | 0 or 1 |
| 13 | last command sequence applied | acknowledgement for the console |
| 14 | live lux | diagnostics |
| 15 | node clock now | diagnostics |
| 16 | PAIR_ID = 42 | rejects other groups on the same Wi-Fi |

### 6.2 Command packet (Console to Security Node), `TYPE_CMD = 2`

| Index | Field | Notes |
|---|---|---|
| 1 | MAGIC | |
| 2 | TYPE = 2 | command |
| 3 | command sequence number | increments on each tap |
| 4 | command code | 0 NONE, 1 ARM, 2 DISARM, 3 SIREN_ON, 4 SIREN_OFF |
| 5 | acknowledged breach number | informational |
| 6 | console clock | informational |
| 7 to 15 | zeros | reserved |
| 16 | PAIR_ID | |

### 6.3 Reliability in three rules

1. **Node sends a heartbeat every 0.5 s** and an extra packet the instant something changes. A lost status packet is replaced 0.5 s later.
2. **Console re-sends its latest command every 0.5 s** with the same sequence number. The node applies a command only when the sequence number is new, so repeats are harmless (idempotent). A lost command is delivered 0.5 s later.
3. **Node echoes the last applied sequence number** (field 13). The console uses it to know whether the command landed.

The harness verifies all requirements with 20% of datagrams deliberately dropped.

---

## 7. File-by-file walkthrough

Files are grouped by layer: configuration, pure logic, glue, model builders, tests, and generated files.

### 7.1 `ids_params.m`: every constant in one place

**Role.** A single function that returns a struct `P` of constants. Every other file receives `P` as an argument instead of hard-coding numbers.

```matlab
function P = ids_params()
P.Ts            = 0.1;      % model base step (s)
P.MAGIC         = 7331;
P.PAIR_ID       = 42;
...
P.ST_DISARMED = 0;  P.ST_ARMING = 1;  P.ST_ARMED = 2;  P.ST_ALARM = 3;
P.lightDeltaAbs = 20;       % lux above baseline
...
end
```

**Python/C++ view.** Like a `config.py` returning a frozen dataclass, or a C++ header full of `constexpr`. Inside the Simulink blocks it is called as `coder.const(ids_params())`, which makes every field a true compile-time constant in the generated C.

**Why a function instead of global variables.** Globals do not translate cleanly to generated code and make tests depend on hidden state. A function returning constants is explicit and safe.

Key groups inside: protocol constants, state and command enums, cause bits, detection thresholds (`lightDeltaAbs`, `tiltThreshDeg`, `gyroThresh`, debounce counts), timing (`armDelaySteps = 50` means 5 s at 10 Hz), audio settings, and `tzOffsetSec = 19800` (IST is UTC + 5 h 30 min = 19800 s).

### 7.2 `node_init.m`: initial state of the Security Node

Returns a struct with every field the node needs, all zeroed. Notable ones:

- `state`: current state machine state.
- `accN, accLux, accPitch, accRoll, accAzS, accAzC`: running sums used to learn the baseline during ARMING.
- `cntLight, cntTilt, cntGyro`: debounce counters.
- `breachSeq, breachEpoch, cause, breachLat, breachLon`: the latched breach record.
- `gps`: last valid GPS fix.
- `lastCmdSeq = -1`: no command applied yet (any real sequence number is different).

**C++ view.** This is the constructor of a `struct NodeState`. Defining every field here is required for code generation, because the struct layout must be fixed.

### 7.3 `node_step.m`: the Security Node brain

**Signature**

```matlab
function [S, tx, txEn, torch, ui] = node_step(S, active, lux, ori, gyro, gps, epoch, rx, rxSize, P)
```

Called once every 0.1 s. Takes the old state `S` and this step's inputs, returns the new state and outputs.

**Step 1: inactive role resets and exits.**

```matlab
if ~active
    S  = node_init();
    ui = [S.state, S.breachSeq, S.cause, S.siren, 0, 0];
    return;
end
```

If this phone is currently the console, the node logic is held in reset and transmits nothing.

**Step 2: keep the last valid GPS fix.**

```matlab
if (gps(1) ~= 0 || gps(2) ~= 0) && all(isfinite(gps(1:3)))
    S.gps = [double(gps(1)), double(gps(2)), double(gps(3))];
end
```

The Location Sensor block outputs zeros when there is no fix (common indoors). Overwriting a good position with zeros would be worse than keeping the last one.

**Step 3: apply new remote commands.**

```matlab
if packet_ok(rx, rxSize, P.TYPE_CMD, P)
    seq  = rx(3);
    code = rx(4);
    if seq ~= S.lastCmdSeq          % only NEW commands
        S.lastCmdSeq = seq;
        forceTx = true;             % confirm quickly
        if code == P.CMD_ARM
            if S.state ~= P.ST_ARMING && S.state ~= P.ST_ARMED
                S = start_arming(S);
            end
        elseif code == P.CMD_DISARM
            S.state = P.ST_DISARMED;
            S.siren = 0;
        elseif code == P.CMD_SIREN_ON
            S.siren = 1;
        elseif code == P.CMD_SIREN_OFF
            S.siren = 0;
        end
    end
end
```

This is where the "apply once per sequence number" rule lives. `forceTx` makes the node reply in this same step so the console sees the confirmation fast.

**Step 4a: ARMING, learn the baseline.**

```matlab
if S.state == P.ST_ARMING
    S.armCtr = S.armCtr + 1;
    if S.armCtr > P.armDelaySteps - P.baselineSteps      % last 10 steps = last 1 s
        S.accN   = S.accN + 1;
        S.accLux = S.accLux + lux;
        ...
        S.accAzS = S.accAzS + sind(az);                  % azimuth on the unit circle
        S.accAzC = S.accAzC + cosd(az);
    end
    if S.armCtr >= P.armDelaySteps && S.accN > 0
        S.baseLux = S.accLux / S.accN;
        ...
        S.baseAz  = atan2d(S.accAzS, S.accAzC);          % circular mean
        S.state = P.ST_ARMED;
    end
```

Why a 5 s exit delay: you tap ARM, then close the drawer. The phone should not alarm on you closing it.

Why learn a baseline instead of fixed thresholds: a drawer might sit at 0.5 lux, a cabinet in a lit room at 40 lux. The detector looks for a **change from where it was armed**, so the same app works in both.

Why sin/cos for azimuth: azimuth is a compass angle that wraps from 359 to 0. A plain average of 359 and 1 is 180, which is badly wrong. Averaging the unit vectors and taking `atan2` gives 0, which is correct. This is the circular mean.

**Step 4b: ARMED, three detectors.**

```matlab
thr = S.baseLux + max(P.lightDeltaAbs, P.lightDeltaRel*S.baseLux);
if lux > thr,  S.cntLight = S.cntLight + 1;  else,  S.cntLight = 0;  end
```

Light trips at baseline + max(20 lux, 100% of baseline). The absolute floor handles dark drawers (0.5 lux baseline, so "100% more" would only be 1 lux, which is noise). The relative term handles bright rooms.

```matlab
dP  = abs(wrap180(pitch - S.basePitch));
dR  = abs(wrap180(roll  - S.baseRoll));
dAz = abs(wrap180(az    - S.baseAz));
tilted = (dP > P.tiltThreshDeg) || (dR > P.tiltThreshDeg) || (P.useAzimuth && dAz > P.azThreshDeg);
```

Tilt compares orientation to the baseline. `wrap180` keeps differences in [-180, 180) so 359 vs 1 is a 2 degree change, not 358. Azimuth gets a wider band (30 degrees) because it uses the magnetometer, which drifts near metal furniture.

```matlab
gmag = sqrt(g(1)^2 + g(2)^2 + g(3)^2);
if gmag > P.gyroThresh, S.cntGyro = S.cntGyro + 1; else, S.cntGyro = 0; end
```

The gyroscope measures rotation rate. Its magnitude catches the phone being picked up even before its final orientation changes much.

**Debouncing.** Each detector must stay true for several consecutive samples (light 3, tilt 3, gyro 2) before it counts. A camera flash or a door slam vibration lasting one sample does not cause an alarm. The counters reset to zero the moment the condition goes false, so this is "N in a row", not "N total".

**Step 4c: latch the breach.**

```matlab
if cause > 0
    S.state       = P.ST_ALARM;
    S.breachSeq   = S.breachSeq + 1;
    S.breachEpoch = epoch;
    S.cause       = cause;
    S.breachLat   = S.gps(1);
    S.breachLon   = S.gps(2);
    forceTx = true;
end
```

`cause` is a bit mask built from the three detectors (1 + 2 + 4), so one number records every reason at once. The breach record is frozen here and does not change until the next breach.

**Step 5: LED strobe.**

```matlab
if S.siren > 0
    torch = double(mod(floor(S.torchCtr / P.torchHalfPeriodSteps), 2) == 0);
    S.torchCtr = S.torchCtr + 1;
```

With `torchHalfPeriodSteps = 2`, the counter sequence 0,1,2,3,4,5,... gives `floor(c/2)` = 0,0,1,1,2,2,... and `mod(...,2)==0` gives 1,1,0,0,1,1. That is 0.2 s on, 0.2 s off. In hardware terms it is a divide-by-4 clock divider.

**Step 6: build the status packet** on every 5th step or immediately if `forceTx`. Field layout is in section 6.1.

**Local function `start_arming`** resets the counters and accumulators and sets the state to ARMING. It sits at the bottom of the file, so only `node_step` can call it.

### 7.4 `console_init.m`: initial state of the Monitoring Console

Fields worth knowing:

- `nodeState = -1`: never heard from the node.
- `alert, alertCause, ackSeq`: alert latch and which breach number has been acknowledged.
- `cmdSeq, cmdCode`: the latest command (re-sent every heartbeat).
- `armIntentSeq, armIntent, sirenIntentSeq, sirenIntent`: commands sent but not yet confirmed (explained below).
- `prevArm, prevSiren, prevAck = -1`: previous button states, used for edge detection. `-1` means "first sample, do not treat as a tap".
- `logHms, logYmd`: the 5-entry breach log.

### 7.5 `console_step.m`: the Monitoring Console brain

**Button edge detection.** The Android Button widget is a **toggle**: each tap flips its output between 0 and 1. A "tap" is therefore any change of value:

```matlab
armTap = (C.prevArm >= 0) && (a ~= C.prevArm);
C.prevArm = a;
```

Same as rising/falling edge detection in RTL: `tap = (btn != btn_q); btn_q <= btn;`.

**Reading a status packet.** On a valid packet the console copies the node's fields, resets `stepsSinceRx`, logs a new breach if the sequence number is higher than the last logged one, and raises the alert:

```matlab
if C.nodeState == P.ST_ALARM && C.breachSeq > C.ackSeq
    C.alert = 1;
    C.alertCause = C.cause;
end
```

"Breach number is higher than the acknowledged number" is what prevents the same breach from re-alerting after you press Acknowledge, while a new breach (#2) still alerts.

If the node reports it has left ALARM (because you disarmed or re-armed it), the alert stops automatically.

**Link supervision.**

```matlab
linkUp = C.everRx && (C.stepsSinceRx < P.linkTimeoutSteps);
if P.linkLostAlarm && C.everRx && ~linkUp && ~C.linkLostAcked && ...
        (C.nodeState == P.ST_ARMED || C.nodeState == P.ST_ALARM)
    C.alert = 1;
    C.alertCause = P.CAUSE_LINKLOST;
end
```

An intruder could simply switch Phone A off. If an armed node goes silent for 5 s, the console alerts with cause 8 (link lost). A disarmed node going silent is ignored.

**Toggle commands with pending intent.** The Arm/Disarm button must decide whether to send ARM or DISARM. The obvious rule is "look at the node's reported state". The problem: if you tap twice quickly, the second tap happens before the node confirms the first, so the console would see the old state and send the same command again. The fix:

```matlab
if C.armIntentSeq > C.nodeCmdAck          % my last ARM/DISARM is still unconfirmed
    armedNow = (C.armIntent == P.CMD_ARM);   % assume it will succeed
else
    armedNow = (C.nodeState == P.ST_ARMING || C.nodeState == P.ST_ARMED || C.nodeState == P.ST_ALARM);
end
```

This is optimistic UI, the same idea as a web app updating the screen before the server replies.

**Outputs for the screen.**

| Output | Contents |
|---|---|
| `uiStatus` | [linkUp, nodeState, siren, alert, alertCause] |
| `uiBreach` | [breachSeq, date YYYYMMDD, time HHMMSS, cause, lat, lon] |
| `uiLive` | [lat, lon, alt, node lux, seconds since last packet] |
| `uiLog` | last 5 breach times HHMMSS, newest first |

Dates and times are shown as plain numbers (for example `20260921` and `194350`) because the Data Display block shows numbers, not text.

### 7.6 `packet_ok.m`: packet validation

```matlab
ok = (rx(1) == P.MAGIC) && (rx(2) == msgType) && (rx(P.PKT_LEN) == P.PAIR_ID);
```

Plus checks that `rxSize > 0` (a fresh packet arrived this step) and that every value is finite.

The `msgType` check is doing double duty. Because the app broadcasts, a phone may receive its **own** packets. A node only accepts command packets and a console only accepts status packets, so a phone's own broadcasts are ignored automatically without needing device IDs.

### 7.7 `wrap180.m`

```matlab
a = a - 360*floor((a + 180)/360);
```

Maps any angle to [-180, 180). Example: 358 becomes -2. Python equivalent: `(a + 180) % 360 - 180`.

### 7.8 `wall_clock.m` and `host_epoch.m`: reading the time

The node needs the current time to stamp a breach. Getting it differs per build target, so the function branches on `coder.target`, which works like `#ifdef`:

```matlab
if coder.target('MATLAB')          % plain MATLAB (unit tests)
    t = host_epoch();
elseif coder.target('Rtw')         % generated C for the phone
    coder.cinclude('<time.h>');
    tt = int64(0);
    tt = coder.ceval('time', coder.opaque('time_t *', 'NULL'));
    t = double(tt);
else                               % Simulink simulation on the PC
    coder.extrinsic('host_epoch');
    t = host_epoch();
end
```

On the phone, the generated C literally becomes `tt = time(NULL);`. `host_epoch.m` is one line using MATLAB's `datetime` and is only used on the PC.

### 7.9 `epoch_to_civil.m`: Unix time to date and time

Converts seconds since 1970 (UTC) into local `YYYYMMDD` and `HHMMSS` numbers using only integer arithmetic, so it compiles to tiny C with no library calls. It is Howard Hinnant's `civil_from_days` algorithm. The trick:

1. Shift the calendar so the year **starts on 1 March**. Then the leap day (29 Feb) is the last day of the year, so month lengths no longer depend on leap years.
2. Count in 400-year **eras** (exactly 146097 days each, because the Gregorian leap rules repeat every 400 years).
3. Inside an era, find the year, then the day of the year, then the month using the linear formula `(5*doy + 2)/153` (months from March follow a regular 153-days-per-5-months pattern).
4. Shift back to January-based months.

The unit test checks it against MATLAB's own `datetime` for several dates, including 29 Feb 2000.

### 7.10 `audio_init.m` and `audio_step.m`: the sound engine

**Interface.** Each call produces one frame of **4410 samples x 2 channels, int16**, which at 44.1 kHz is exactly 0.1 s of audio, matching the model step. That is the format the Android Audio Playback block expects.

**Siren synthesis (node).** A software oscillator, the same structure as a DDS/NCO in hardware:

```matlab
A.sweep = A.sweep + dSweep;                      % slow ramp 0 -> 1 every 0.5 s
tri = 1 - abs(2*A.sweep - 1);                    % triangle: 0 -> 1 -> 0
f   = P.sirenLoHz + (P.sirenHiHz - P.sirenLoHz)*tri;   % 650 -> 1500 -> 650 Hz
A.ph = A.ph + 2*pi*f/P.Fs;                       % phase accumulator
v = 1.6*sin(A.ph);
y(n) = y(n) + P.sirenAmp*min(max(v, -1), 1);     % overdrive then clip
```

- The phase accumulator keeps the waveform continuous across frames, so there are no clicks every 0.1 s. That is why `A.ph` is part of the persistent state.
- Multiplying by 1.6 and clipping at plus/minus 1 turns the sine into a softened square wave. Square waves have strong harmonics, which sound much louder on a small phone speaker at the same peak level.

**Message playback (console).** Plays the recorded samples, then 1 s of silence, then repeats, while the alert is active:

```matlab
if A.msgPos < L
    y(n) = y(n) + double(msg(A.msgPos + 1))/32768;   % +1 because MATLAB is 1-based
end
A.msgPos = A.msgPos + 1;
if A.msgPos >= period, A.msgPos = 0; end
```

When the alert stops, `msgPos` resets so the next alert starts from the beginning of the sentence.

**Final conversion.**

```matlab
s = int16(round(y*32767));
audio = [s, s];          % same signal on left and right
```

`int16()` saturates rather than wrapping (unlike a C cast), which is a safety net against clicks from overflow.

### 7.11 `make_alert_audio.m`: preparing the recorded message

Reads `alert_message.wav` (currently a text-to-speech recording saying "Intrusion alert! The security node has been breached."), converts it to mono, resamples to 44.1 kHz with `interp1` (no Signal Processing Toolbox needed), trims silence, normalises to 90% of full scale, and saves `alert_message.mat` containing an `int16` vector `msg`.

The AudioEngine block reads that `.mat` file with `coder.load`, so the samples are compiled **into** the app. To use your own voice, record a WAV, save it over `alert_message.wav`, run `make_alert_audio`, and rebuild. If no WAV exists it synthesises a two-tone chime so the build never breaks.

### 7.12 `build_security_core.m`: the shared core subsystem

Creates the `SecurityCore` subsystem inside any parent model:

1. Adds an empty Subsystem block and deletes its default In1/Out1.
2. Adds 11 Inport and 11 Outport blocks with meaningful names.
3. Adds two MATLAB Function blocks and sets their code through the Stateflow API:

```matlab
rt = sfroot;
ch = rt.find('-isa', 'Stateflow.EMChart', 'Path', blkPath);
ch.Script = code;
```

(MATLAB Function blocks are stored internally as a kind of Stateflow chart. This is just the API to set their source text. No Stateflow license is needed.)

4. Wires inports to the Controller, Controller outputs to outports and to the AudioEngine.

The **Controller** block code is:

```matlab
function [tx, txEn, torch, sirenOn, alertOn, uiNode, uiStatus, uiBreach, uiLive, uiLog] = controller(role, lux, ori, gyro, gps, epoch, rx, rxSize, btnArm, btnSiren, btnAck)
P = coder.const(ids_params());
persistent N C
if isempty(N)
    N = node_init();
    C = console_init(P.logLen);
end
isNode = double(role(1)) < 1.5;
[N, txN, enN, torchD, uiNode] = node_step(N, isNode, ...);
[C, txC, enC, uiStatus, uiBreach, uiLive, uiLog] = console_step(C, ~isNode, ...);
if isNode, tx = txN; txEn = enN; else, tx = txC; txEn = enC; end
torch   = int32(torchD);
sirenOn = double(isNode && N.siren > 0);
alertOn = double(~isNode && C.alert > 0);
end
```

Both roles run every step, but the inactive one receives `active = false` and stays in reset. This is requirement 4 in a few lines: a phone switches role simply by flipping `isNode`.

Notice the variable `torchD` (double) is converted into a new variable `torch` (int32). In generated code a variable cannot change type, so you create a new one, just as you would declare a new variable in C++.

### 7.13 `build_android_model.m`: the deployable app

Builds `ids_android_app.slx`. Options (MATLAB "name-value" arguments, parsed with `inputParser`, like Python kwargs):

```matlab
build_android_model                                   % defaults
build_android_model('PeerIP', '192.168.43.42')        % send to one IP instead of broadcast
build_android_model('EnableTorch', false)             % no LED hook, deploy with one click
build_android_model('AllowStubs', true)               % placeholder blocks, for review without the support package
```

What it does, in order:

1. **Finds the Android block library** (`find_android_library`). It tries known library names, then scans every `slblocks.m` on the path whose folder name contains "android". `slblocks.m` is how a toolbox registers its library with the Library Browser.
2. **Configures the model**: fixed-step discrete solver, `Ts = 0.1`, stop time `inf` (runs forever on the phone), hardware board "Android Device".
3. **Adds `SecurityCore`** via `build_security_core`.
4. **Adds the sensor blocks** and sets their sample time. `to_double` inserts a Data Type Conversion, and a Mux first if a block has several output ports (some Location Sensor versions have separate Lat/Lon/Alt ports).
5. **Adds WallClock**, a MATLAB Function block calling `wall_clock()` with an explicit 0.1 s sample time (it has no inputs, so Simulink cannot infer one).
6. **Adds UDP Receive**: port 25000, type double, size 16.
7. **Adds four Buttons**. The role button goes through a Bias block (+1) so released = 1 (node) and pressed = 2 (console).
8. **Adds outputs**: an Enabled Subsystem "Transmit" containing UDP Send (only sends when `txEn` is true), Audio Playback at 44100 Hz, the ToApp block named `TorchControl`, and five Data Display blocks.
9. Adds an annotation explaining the codes, auto-arranges, and saves.

**Setting block parameters robustly (`setp`).** Different versions of the support package use different internal parameter names, but the dialog labels ("Sample time", "Remote IP port") are stable. So `setp` looks up the parameter **by its label**:

```matlab
names   = get_param(blk, 'MaskNames');     % internal names
prompts = get_param(blk, 'MaskPrompts');   % labels shown in the dialog
idx = find(~cellfun(@isempty, regexpi(prompts, promptRegex, 'once')), 1);
set_param(blk, names{idx}, value);
```

`cellfun(@isempty, ...)` applies `isempty` to every element of a cell array, like Python's `[not m for m in matches]`. If no label matches, it prints a warning telling you which parameter to set by hand.

**Stub mode (`make_stub`).** When the support package is missing, each Android block is replaced by an orange subsystem with the same ports and output types. This was used to verify that the builder logic and wiring are correct. The result is saved as `ids_android_app_stub.slx` and cannot be deployed.

### 7.14 `patch_android_torch.m`: adding camera LED control

The Android support package has no flashlight block. The model sends the LED state to a **ToApp** block, which calls a Java method named `TorchControl` in the app's main Activity. This script writes that method into the generated Java code:

```java
public void TorchControl(int[] data) {
    final boolean on = (data != null && data.length > 0 && data[0] != 0);
    if (on == idsTorchOn) return;               // only act on changes
    idsTorchOn = on;
    ...
    cm.setTorchMode(idsTorchCam, on);           // Android Camera2 API
}
```

Steps it performs:

1. Finds the generated main Activity file (`<model>.java`) under `<model>_ert_rtw`.
2. If a `TorchControl` stub already exists it replaces it (finding the method's end by brace matching), otherwise it inserts the method before the class's closing brace. A marker comment `IDS_TORCH_PATCH` prevents patching twice.
3. Runs `gradlew.bat installDebug` to build and install the APK, then launches it with `adb`.

Because Simulink regenerates the Java on every build, you re-run this script after each rebuild.

### 7.15 `ids_scenario.m`: the scripted test story

Builds time-series matrices in the From Workspace format `[t, value1, value2, ...]` for every sensor and button on both simulated phones. The story (130 s):

| Time | Event | Expected result |
|---|---|---|
| 5 s | B taps Arm | A arms, ARMED at 10 s |
| 30 s | A's lux jumps to 80 for 3 s | breach #1 (light), B alerts |
| 35 s | B taps Siren | A siren + LED strobe |
| 45 s | B taps Acknowledge | B's voice alert stops |
| 50 s | B taps Arm/Disarm | A disarmed, siren off |
| 60 s | B taps Arm | A re-armed |
| 75 s | A picked up (gyro spike + 25 degree tilt) | breach #2 |
| 85 s | B taps Arm/Disarm | A disarmed |
| 90 s | **roles swap** | A becomes console, B becomes node |
| 95 s | A taps Arm | B arms |
| 110 s | B's lux jumps to 120 | A (now console) alerts |

The local function `toggles` turns tap times into the toggle-button signal by XOR-ing a step at each tap time.

### 7.16 `build_sim_harness.m`: the two-phone test bench

Creates `ids_sim_harness.slx` (diagram 2.6):

- **Digital Clock + Constant + Add** produce a fake wall clock (base epoch + simulation time), so breach times are deterministic.
- **WiFi_Network** (MATLAB Function) passes each phone's packet to the other and drops 20% using a linear congruential generator:

```matlab
s = mod(1664525*s + 1013904223, 4294967296);   % classic LCG, same constants as Numerical Recipes
uA = s/4294967296;                             % uniform in [0, 1)
```

  A hand-written generator is used instead of `rand` so every run drops exactly the same packets. Tests stay reproducible.
- **Unit Delays** add 0.1 s latency and break the algebraic loop (section 5).
- **To Workspace** blocks log every UI output, LED, siren and the audio frame peak (via Data Type Conversion, Abs and MinMax, so it logs one number per frame instead of 8820 samples).
- Scenario data is stored in the **model workspace**, so the `.slx` file is self-contained.

### 7.17 `run_harness_test.m`: end-to-end checks

Builds the harness, runs `out = sim(mdl)`, and checks 13 requirements against the logged signals. Small helpers make the checks readable:

```matlab
at    = @(x, tq) x(find(t >= tq - 1e-6, 1), :);   % value of signal x at time tq
win   = @(tq0, tq1) (t >= tq0 - 1e-6 & t <= tq1 + 1e-6);   % logical mask for a time window
first = @(mask) t(find(mask, 1));                 % first time a condition is true
```

`find(mask, 1)` returns the index of the first true element (Python: `np.argmax(mask)` when one exists).

`as_rows` fixes a MATLAB quirk: To Workspace logs a 1xK signal as a 1xKxN 3-D array. `permute` + `reshape` turns it into the expected N x K table (like `np.transpose` + `reshape`).

It finally draws `harness_timeline.png` with five stacked plots (node state, light, console alert, siren/LED, audio).

### 7.18 `test_logic_units.m`: 37 fast unit tests

Calls the `.m` logic functions directly in plain MATLAB with no Simulink, so it runs in seconds. Structure:

- `add(results, name, pass)` records and prints PASS/FAIL (a minimal assert helper).
- `cmdpkt(P, seq, code)` and `statpkt(...)` are fixtures that build valid packets.
- `quiet = @(S, cmd, lux, ori, gyro) node_step(S, true, lux, ori, gyro, [23.2 72.6 50], 1.79e9, cmd, 1, P);` is a lambda that fills in the arguments that do not matter for a given test.

Groups of tests: clock conversion, node arming and baseline, duplicate command rejection, own-broadcast and wrong-pair rejection, light debouncing, motion and tilt detection, azimuth wrap-around, GPS retention, LED strobe pattern, console alert/ack logic, link-lost alarm, siren toggling, pending-intent toggling, and audio frame format, loudness and message looping.

This is possible only because the logic files are **pure functions with explicit state** (section 8).

### 7.19 `README.md`

Short operational instructions: install, build, deploy, use. This guide is the long version.

### 7.20 Generated and helper files in the folder

| File | What it is | Safe to delete? |
|---|---|---|
| `alert_message.wav` | recorded alert sentence (Windows text-to-speech) | keep, or replace with your voice |
| `alert_message.mat` | the same audio as an int16 vector, embedded into the app | regenerated by `make_alert_audio` |
| `ids_sim_harness.slx` | the two-phone test model | regenerated by `run_harness_test` |
| `ids_android_app_stub.slx` | placeholder build for review | yes |
| `ids_android_app.slx` | the real app (after you install the support package and build) | regenerated by `build_android_model` |
| `harness_timeline.png` | plot from the last harness run | regenerated |
| `stub_view.png`, `stub_core.png` | screenshots of the stub model | yes |
| `slprj/`, `*.slxc` | Simulink build cache (compiled MATLAB Function blocks) | yes, rebuilt automatically |
| `_run.ps1`, `_log_*.txt`, `_done_*.txt` | helper script and logs used to run MATLAB in the background while building this | yes |

---

## 8. Design decisions and why

**One app, role chosen at runtime.** Requirement 4 says both phones must be interchangeable. Two separate apps would need two builds and two installs, and could drift apart. One app with a role switch is simpler and guarantees both phones speak the same protocol version.

**Pure step functions with explicit state (`S = f(S, inputs)`) instead of persistent variables inside the logic.** The logic can be unit tested in plain MATLAB by feeding inputs and checking outputs, with no Simulink involved. Two independent instances (Phone_A and Phone_B) are trivial. The only persistent variables live in the thin MATLAB Function block wrappers.

**State-based, idempotent commands with sequence numbers.** Commands are re-sent until confirmed and applied once per sequence number. Lost packets just cause a short delay, and duplicates do nothing.

**Heartbeat + immediate send on events.** Events reach the console within about 0.1 s, while the heartbeat keeps the link supervision alive and recovers from losses.

**Broadcast by default, PAIR_ID filtering.** No IP configuration on either phone. The pair ID stops two groups in the same lab from controlling each other's phones.

**Relative thresholds with a learnt baseline, plus debouncing.** Works in a dark drawer and a lit cabinet, ignores single-sample glitches.

**Siren synthesised in code instead of an audio file.** No file to load, perfectly continuous tone, and the volume is fixed by the code.

**Recorded message compiled into the app.** No file access on the phone at runtime, so no storage permissions are needed.

**Shared `SecurityCore` between the app and the harness.** The thing you test is the thing you ship.

**Models built by scripts.** Reproducible, versionable, and easy to rebuild after any change.

---

## 9. Testing strategy

Three levels, from fastest to most realistic:

| Level | Command | Time | What it proves |
|---|---|---|---|
| Unit | `test_logic_units` | seconds | each state machine, the clock math and the audio engine behave correctly in isolation (37 checks) |
| System (simulated) | `run_harness_test` | about 2 to 4 minutes | two complete cores, wired through a lossy network, satisfy all requirements including the role swap (13 checks) |
| Hardware | deploy to two phones | minutes per build | the real sensors, Wi-Fi and speaker behave as the simulation assumed |

Last recorded results on your machine: **37 / 37** and **13 / 13** passing.

Workflow rule: whenever you change `ids_params.m` or any logic file, run the two test commands **before** rebuilding the phone app. If they pass, any problem on the phones is in the sensors or network, not in your logic.

---

## 10. Limitations and things to know before the demo

Be upfront about these in a viva. They are also good "future work" points.

- **Not yet run on physical phones.** Everything except the Android-specific blocks has been executed and tested. The Android Support Package was not installed on this computer, so the real app has not been built or deployed yet. Some block dialog labels may differ in your support package version: the builder prints a warning naming any parameter it could not set.
- **iOS is not possible with your MATLAB.** MathWorks shipped the Apple iOS support package only up to **R2023a**. You have R2024a, so this project targets Android. If the assignment insists on iOS, it would need an older MATLAB plus a Mac with an old Xcode.
- **The LED patch is untested** because it depends on the layout of the generated Android project. If `patch_android_torch` cannot find the files, use `build_android_model('EnableTorch', false)` for the demo: everything else works with a one-click deploy.
- **Campus Wi-Fi often blocks phone-to-phone traffic and broadcasts** ("client isolation"). Use a mobile hotspot from a third phone or laptop, and if broadcast still fails, rebuild with `'PeerIP'` set to the other phone's IP on each side.
- **Keep the app in the foreground with the screen on.** Android may pause sensors or the app when the screen locks. Turn on Developer options > Stay awake while charging, and disable battery optimisation for the app.
- **The light sensor is next to the front camera**, so place the node phone face-up.
- **GPS indoors may never get a fix.** The node then sends zeros until the first fix, after which it keeps the last good one.
- **No encryption or authentication.** Anyone on the same network who knows the packet format could send DISARM. A real product would add a shared-key message authentication code (HMAC) to each packet. The magic number and pair ID only prevent accidents, not attacks.
- **Breach timestamps use the node phone's clock.** If that clock is wrong, the logged time is wrong (the console falls back to its own clock only when the node sends zero).

---

## 11. How to modify things

| I want to... | Change | Then |
|---|---|---|
| make light detection more or less sensitive | `lightDeltaAbs`, `lightDeltaRel`, `lightDebounce` in `ids_params.m` | run tests, rebuild |
| change tilt / motion sensitivity | `tiltThreshDeg`, `azThreshDeg`, `useAzimuth`, `gyroThresh` | run tests, rebuild |
| change the exit delay | `armDelaySteps` (steps of 0.1 s) | run tests, rebuild |
| use my own voice message | record `alert_message.wav`, run `make_alert_audio` | rebuild |
| avoid clashing with another group | change `PAIR_ID` (same value on both phones) | rebuild both |
| change the siren sound | `sirenLoHz`, `sirenHiHz`, `sirenSweepSec` | rebuild |
| change the LED strobe speed | `torchHalfPeriodSteps` | rebuild |
| show times in another timezone | `tzOffsetSec` | rebuild |
| add a new command | add a `CMD_` code in `ids_params.m`, handle it in `node_step.m`, send it from `console_step.m` (plus a Button in `build_android_model.m`) | add a unit test, run both test suites, rebuild |

---

## 12. Glossary

| Term | Meaning |
|---|---|
| `.m` file | MATLAB source file (a function or a script) |
| `.slx` file | Simulink model (a block diagram, stored as a zipped XML) |
| `.mat` file | MATLAB binary data file (like a `.npz`) |
| Path | list of folders MATLAB searches for functions (like `sys.path`) |
| Workspace | variables currently in memory |
| MATLAB Function block | a Simulink block whose behaviour is written in MATLAB code |
| Subsystem | a block that contains other blocks (a hierarchical module) |
| Mask | the dialog and parameters wrapped around a library block |
| Sample time | how often a block executes (0.1 s here) |
| Fixed-step discrete solver | the simulation advances in equal steps with no continuous dynamics (a clocked circuit) |
| Code generation | translating the model into C (Simulink Coder / Embedded Coder) |
| Support package | MathWorks add-on that adds hardware blocks and a build flow for a device (here Android) |
| Hardware board | the target selected in Model Settings that decides how the model is built and deployed |
| ToApp block | Android block that calls a Java method in the generated app |
| NDK | Android Native Development Kit, compiles the generated C for the phone |
| APK | Android app package |
| Epoch time | seconds since 1970-01-01 00:00:00 UTC |
| Debounce | requiring a condition for N consecutive samples before acting |
| Idempotent | applying the same command twice has the same effect as applying it once |
| Heartbeat | periodic packet proving the sender is alive |
