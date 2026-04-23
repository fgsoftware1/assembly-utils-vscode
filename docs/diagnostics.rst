Diagnostic Codes
=================

This document lists all diagnostic codes produced by gaslsp.

Severity
--------

- **Error**: Compilation will fail
- **Warning**: May cause unexpected behavior

Size Diagnostics (D001-D003)
----------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 15 70

   * - Code
     - Severity
     - Description

   * - D001
     - Error
     - Missing size suffix with no operand to infer size from (e.g., ``push $42``)

   * - D002
     - Warning
     - No size suffix inferred; size inferred from operand register

   * - D003
     - Error
     - Operand size mismatch: suffix size doesn't match register size

Operand Diagnostics (D004-D005, D009-D010, D018)
----------------------------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 15 70

   * - Code
     - Severity
     - Description

   * - D004
     - Warning
     - Immediate value doesn't fit in operand size (e.g., ``$256`` for 8-bit)

   * - D005
     - Error
     - High-byte register (``%ah``, ``%bh``, ``%ch``, ``%dh``) conflicts with REX prefix

   * - D009
     - Error
     - 32-bit base register (``%ebp``, ``%ebx``, etc.) in 64-bit memory operand

   * - D010
     - Warning
     - Source and destination registers are the same (no-op)

   * - D018
     - Error
     - Incomplete label: identifier without colon that isn't an instruction

Encoding Diagnostics (D011-D015)
--------------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 15 70

   * - Code
     - Severity
     - Description

   * - D011
     - Error
     - ``div``/``idiv`` with immediate operand (not encodable)

   * - D012
     - Error
     - ``pushb`` not encodable; push only supports 16/32/64-bit

   * - D013
     - Warning
     - One-operand ``imul``: high half of result in ``%rdx`` may be unexpected

   * - D014
     - Warning
     - ``mul`` is unsigned; upper half in ``%rdx`` may be silently discarded

   * - D015
     - Error
     - Shift count must be ``%cl`` or immediate; other registers not encodable

ABI Diagnostics (D016-D017)
---------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 15 70

   * - Code
     - Severity
     - Description

   * - D016
     - Warning
     - ``syscall`` clobbers ``%rcx`` and ``%r11``

   * - D017
     - Warning
     - ``int $0x80`` is 32-bit syscall ABI; use ``syscall`` instead

Symbol Diagnostics (D006-D008, D019)
------------------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 15 70

   * - Code
     - Severity
     - Description

   * - D006
     - Error
     - Undefined symbol reference

   * - D007
     - Warning
     - Symbol referenced from another file but not declared ``.global``

   * - D008
     - Error
     - Duplicate symbol definition

   * - D019
      - Warning
      - ``_start`` or ``main`` defined but not exported

State Diagnostics (D034)
-------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 15 70

   * - Code
     - Severity
     - Description

   * - D034
     - Warning
     - Register may be read before being written (uninitialized)

Configuration
--------------

Diagnostics can be suppressed or promoted to errors in ``gaslsp.toml``:

.. code-block:: toml

   [diagnostics]
   suppress = ["D002", "D014"]           # Disable specific codes
   warnings_as_errors = ["D010"]          # Promote warnings to errors

   [diagnostics.categories]
   size = true      # D001-D003
   operand = true   # D004-D005, D009-D010, D018
   encoding = true  # D011-D015
   abi = true      # D016-D017
   symbol = true    # D006-D008, D019
   state = true     # D034: uninitialized register tracking
