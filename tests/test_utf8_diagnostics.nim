## A malformed model glyph must not turn rejected input into invalid UTF-8 logs.
import std/[os, osproc, strutils]
import babel/sim

if paramCount() == 1 and paramStr(1) == "--invalid-glyph":
  discard Sim().tokenOf(0, "\xED\xB0\x80")
  quit(0)

let child = execCmdEx(quoteShell(getAppFilename()) & " --invalid-glyph")
doAssert child.exitCode != 0
doAssert "not a glyph of this alphabet" in child.output
let decoded = execCmdEx("python3 -c " & quoteShell(
  "import sys; sys.stdin.buffer.read().decode('utf-8')"), input = child.output)
doAssert decoded.exitCode == 0,
  "rejected glyph diagnostics must remain readable by UTF-8 log collectors"
echo "invalid glyph diagnostics remain valid UTF-8"
